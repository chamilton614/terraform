#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# drift_fixer.sh
#
# End-to-end workflow:
#   Phase 1 – Detect drift          (terraform plan)
#   Phase 2 – Analyze & investigate  (terraform state + az CLI)
#   Phase 3 – Generate fix script    (terraform import / state rm commands)
#   Phase 4 – (Optional) Execute     (apply the fixes)
###############################################################################

# ── Colours / helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC}   $*" >&2; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }

WORK_DIR="$(pwd)/.drift-fixer"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
REPORT_DIR="${WORK_DIR}/${TIMESTAMP}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

OPTIONS
  -d, --dir <path>         Terraform working directory (default: .)
  -b, --backup             Back up state before any changes  (default: on)
  -e, --execute            Execute generated fix commands automatically
  -t, --target <addr>      Only analyse a specific resource address
  -v, --var-file <file>    Pass a tfvars file to terraform plan
      --skip-azure-lookup  Skip Azure CLI lookups (offline mode)
      --tf-version-gte-15  Generate TF 1.5+ import blocks instead of CLI cmds
  -h, --help               Show this help

EXAMPLES
  # Basic drift detection + fix script generation
  ./drift_fixer.sh --dir ./infra

  # Target a single resource
  ./drift_fixer.sh --target 'module.network.azurerm_virtual_network.main'

  # Auto-execute fixes (use with caution!)
  ./drift_fixer.sh --execute
EOF
  exit 0
}

# ── Defaults ─────────────────────────────────────────────────────────────────
TF_DIR="."
BACKUP=true
EXECUTE=false
TARGET=""
VARFILE=""
SKIP_AZ=false
TF15_IMPORT_BLOCKS=false

# ── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir)               TF_DIR="$2";              shift 2;;
    -b|--backup)            BACKUP=true;               shift;;
    -e|--execute)           EXECUTE=true;              shift;;
    -t|--target)            TARGET="$2";               shift 2;;
    -v|--var-file)          VARFILE="$2";              shift 2;;
    --skip-azure-lookup)    SKIP_AZ=true;              shift;;
    --tf-version-gte-15)    TF15_IMPORT_BLOCKS=true;   shift;;
    -h|--help)              usage;;
    *)                      err "Unknown option: $1"; usage;;
  esac
done

# ── Pre-flight checks ───────────────────────────────────────────────────────
for cmd in terraform python3 jq; do
  command -v "$cmd" &>/dev/null || { err "$cmd is required but not installed"; exit 1; }
done

if [[ "$SKIP_AZ" == false ]]; then
  command -v az &>/dev/null || { warn "az CLI not found – Azure lookups will be skipped"; SKIP_AZ=true; }
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE_SCRIPT="${SCRIPT_DIR}/parse_drift.py"
[[ -f "$PARSE_SCRIPT" ]] || { err "parse_drift.py not found at ${PARSE_SCRIPT}"; exit 1; }

mkdir -p "$REPORT_DIR"
log "Working directory : $TF_DIR"
log "Report directory  : $REPORT_DIR"

cd "$TF_DIR"

###############################################################################
# PHASE 0 – Initialise
###############################################################################
log "Phase 0: terraform init (if needed)..."
if [[ ! -d .terraform ]]; then
  terraform init -input=false -no-color > "${REPORT_DIR}/init.log" 2>&1
  ok "terraform init completed"
else
  ok "Already initialised"
fi

###############################################################################
# PHASE 1 – Detect Drift (terraform plan)
###############################################################################
log "Phase 1: Running terraform plan to detect drift..."

PLAN_ARGS=(-input=false -detailed-exitcode -out="${REPORT_DIR}/tfplan")
[[ -n "$VARFILE" ]] && PLAN_ARGS+=(-var-file="$VARFILE")
[[ -n "$TARGET" ]]  && PLAN_ARGS+=(-target="$TARGET")

PLAN_EXIT=0
terraform plan "${PLAN_ARGS[@]}" -no-color > "${REPORT_DIR}/plan_human.txt" 2>&1 || PLAN_EXIT=$?

# Exit code 0 = no changes, 1 = error, 2 = changes present
case $PLAN_EXIT in
  0)
    ok "No drift detected – state is in sync!"
    exit 0
    ;;
  1)
    err "terraform plan failed. See ${REPORT_DIR}/plan_human.txt"
    cat "${REPORT_DIR}/plan_human.txt"
    exit 1
    ;;
  2)
    warn "Drift detected! Analysing..."
    ;;
esac

# Generate JSON plan
terraform show -json "${REPORT_DIR}/tfplan" > "${REPORT_DIR}/plan.json" 2>/dev/null
ok "Plan JSON written to ${REPORT_DIR}/plan.json"

# Human-readable summary
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  DRIFT SUMMARY (human-readable plan)"
echo "════════════════════════════════════════════════════════════════"
grep -E '^\s+#|Plan:|^[~+\-]' "${REPORT_DIR}/plan_human.txt" || true
echo "════════════════════════════════════════════════════════════════"
echo ""

###############################################################################
# PHASE 2 – Pull current state & investigate each drifted resource
###############################################################################
log "Phase 2: Investigating drifted resources..."

# Pull full state as JSON
terraform state pull > "${REPORT_DIR}/state.json" 2>/dev/null
ok "Current state saved to ${REPORT_DIR}/state.json"

# List all resources in state
terraform state list > "${REPORT_DIR}/state_list.txt" 2>/dev/null
ok "State resource list saved ($(wc -l < "${REPORT_DIR}/state_list.txt") resources)"

# For each resource in state, dump detailed info
mkdir -p "${REPORT_DIR}/state_show"
while IFS= read -r resource_addr; do
  safe_name="$(echo "$resource_addr" | tr '/:[]"' '_')"
  terraform state show -no-color "$resource_addr" \
    > "${REPORT_DIR}/state_show/${safe_name}.txt" 2>/dev/null || true
done < "${REPORT_DIR}/state_list.txt"
ok "Individual state snapshots saved to ${REPORT_DIR}/state_show/"

###############################################################################
# PHASE 2b – Azure CLI resource lookups (optional)
###############################################################################
AZ_LOOKUP_FILE="${REPORT_DIR}/azure_resources.json"
if [[ "$SKIP_AZ" == false ]]; then
  log "Phase 2b: Querying Azure for current resource inventory..."

  # Get current subscription
  SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null)"
  log "  Subscription: ${SUBSCRIPTION_ID}"

  # Dump all resources in the subscription (or specific RGs from state)
  # Extract resource group names from the state
  RESOURCE_GROUPS="$(jq -r '
    .resources[]?.instances[]?.attributes?.resource_group_name // empty
  ' "${REPORT_DIR}/state.json" | sort -u)"

  echo '[]' > "$AZ_LOOKUP_FILE"

  if [[ -n "$RESOURCE_GROUPS" ]]; then
    for rg in $RESOURCE_GROUPS; do
      log "  Scanning resource group: $rg"
      az resource list --resource-group "$rg" -o json 2>/dev/null | \
        jq -s '.[0] + .[1]' "$AZ_LOOKUP_FILE" - > "${AZ_LOOKUP_FILE}.tmp" && \
        mv "${AZ_LOOKUP_FILE}.tmp" "$AZ_LOOKUP_FILE"
    done
  else
    log "  Scanning entire subscription..."
    az resource list -o json > "$AZ_LOOKUP_FILE" 2>/dev/null
  fi

  AZ_RESOURCE_COUNT="$(jq length "$AZ_LOOKUP_FILE")"
  ok "Found ${AZ_RESOURCE_COUNT} Azure resources"
else
  echo '[]' > "$AZ_LOOKUP_FILE"
  warn "Azure CLI lookup skipped"
fi

###############################################################################
# PHASE 3 – Parse, correlate, and generate fix commands
###############################################################################
log "Phase 3: Generating fix commands..."

PYTHON_ARGS=(
  "$PARSE_SCRIPT"
  --plan-json     "${REPORT_DIR}/plan.json"
  --state-json    "${REPORT_DIR}/state.json"
  --state-list    "${REPORT_DIR}/state_list.txt"
  --azure-json    "$AZ_LOOKUP_FILE"
  --output-dir    "${REPORT_DIR}"
  --state-show-dir "${REPORT_DIR}/state_show"
)
[[ "$TF15_IMPORT_BLOCKS" == true ]] && PYTHON_ARGS+=(--import-blocks)

python3 "${PYTHON_ARGS[@]}"

ok "Fix scripts generated in ${REPORT_DIR}/"

# ── Display report ───────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  DRIFT ANALYSIS REPORT"
echo "════════════════════════════════════════════════════════════════"
cat "${REPORT_DIR}/drift_report.txt" 2>/dev/null || warn "No report file found"
echo "════════════════════════════════════════════════════════════════"
echo ""

echo "Generated files:"
echo "  📄 ${REPORT_DIR}/drift_report.txt         – Human-readable report"
echo "  📄 ${REPORT_DIR}/drift_details.json        – Machine-readable details"
echo "  🔧 ${REPORT_DIR}/fix_state.sh              – Fix commands (state rm + import)"
echo "  🔧 ${REPORT_DIR}/fix_state_safe.sh         – Safe version (with confirmations)"
if [[ "$TF15_IMPORT_BLOCKS" == true ]]; then
  echo "  📄 ${REPORT_DIR}/imports.tf               – TF 1.5+ import blocks"
fi
echo ""

###############################################################################
# PHASE 4 – Backup & optionally execute
###############################################################################
if [[ "$BACKUP" == true ]]; then
  log "Phase 4a: Backing up current state..."
  cp "${REPORT_DIR}/state.json" "${REPORT_DIR}/state_BACKUP_${TIMESTAMP}.json"
  ok "State backed up to ${REPORT_DIR}/state_BACKUP_${TIMESTAMP}.json"
fi

if [[ "$EXECUTE" == true ]]; then
  log "Phase 4b: Executing fixes..."
  warn "This will modify your Terraform state. Continue? (y/N)"
  read -r confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    bash "${REPORT_DIR}/fix_state.sh" 2>&1 | tee "${REPORT_DIR}/fix_execution.log"
    ok "Fixes applied. Running verification plan..."
    terraform plan -no-color > "${REPORT_DIR}/plan_after_fix.txt" 2>&1 || true
    echo ""
    echo "Post-fix plan:"
    cat "${REPORT_DIR}/plan_after_fix.txt"
  else
    log "Execution cancelled."
  fi
else
  echo ""
  log "To apply fixes, review and run:"
  echo "    bash ${REPORT_DIR}/fix_state.sh"
  echo ""
  log "Or re-run with --execute flag (after reviewing the script!)"
fi

ok "Done! 🎉"