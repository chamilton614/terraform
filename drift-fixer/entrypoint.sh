#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# entrypoint.sh — Container entrypoint for drift-fixer
###############################################################################

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

DRIFT_FIXER="${DRIFT_FIXER_HOME}/scripts/drift_fixer.sh"
AZ_LOOKUP="${DRIFT_FIXER_HOME}/scripts/azure_id_lookup.sh"

# ── Print tool versions ─────────────────────────────────────────────────────
print_versions() {
    echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          Terraform Drift Fixer — Tool Versions       ║${NC}"
    echo -e "${CYAN}╠═══════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  Terraform : $(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || echo 'unknown')$(printf '%*s' 32 '')${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  Azure CLI : $(az version 2>/dev/null | jq -r '."azure-cli"' 2>/dev/null || echo 'unknown')$(printf '%*s' 33 '')${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  Python    : $(python3 --version 2>/dev/null | awk '{print $2}')$(printf '%*s' 31 '')${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  jq        : $(jq --version 2>/dev/null)$(printf '%*s' 33 '')${CYAN}║${NC}"
    echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ── Validate Azure authentication ───────────────────────────────────────────
check_azure_auth() {
    if az account show &>/dev/null; then
        local sub_name sub_id
        sub_name="$(az account show --query name -o tsv 2>/dev/null)"
        sub_id="$(az account show --query id -o tsv 2>/dev/null)"
        echo -e "${GREEN}✓ Azure authenticated${NC}"
        echo -e "  Subscription: ${sub_name} (${sub_id})"
        return 0
    else
        echo -e "${YELLOW}⚠ Not authenticated to Azure${NC}"
        echo ""
        echo "Options to authenticate:"
        echo "  1. Mount host credentials:  -v \$HOME/.azure:/root/.azure"
        echo "  2. Service principal env vars (see below)"
        echo "  3. Run 'az login' inside the container"
        echo ""

        # Try service principal auth if env vars are set
        if [[ -n "${AZURE_CLIENT_ID:-}" && -n "${AZURE_CLIENT_SECRET:-}" && -n "${AZURE_TENANT_ID:-}" ]]; then
            echo -e "${CYAN}Attempting service principal login...${NC}"
            az login --service-principal \
                --username "${AZURE_CLIENT_ID}" \
                --password "${AZURE_CLIENT_SECRET}" \
                --tenant "${AZURE_TENANT_ID}" \
                --output none 2>/dev/null

            if [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
                az account set --subscription "${AZURE_SUBSCRIPTION_ID}" 2>/dev/null
            fi

            echo -e "${GREEN}✓ Service principal authentication successful${NC}"
            return 0
        fi

        # Try managed identity
        if [[ -n "${MSI_ENDPOINT:-}" || -n "${IDENTITY_ENDPOINT:-}" ]]; then
            echo -e "${CYAN}Attempting managed identity login...${NC}"
            az login --identity --output none 2>/dev/null && \
                echo -e "${GREEN}✓ Managed identity authentication successful${NC}" && \
                return 0
        fi

        echo -e "${YELLOW}Continuing without Azure auth (lookups will be skipped)${NC}"
        return 1
    fi
}

# ── Validate workspace ───────────────────────────────────────────────────────
check_workspace() {
    local dir="${1:-.}"

    if [[ ! -d "$dir" ]]; then
        echo -e "${RED}✗ Directory not found: ${dir}${NC}" >&2
        echo "  Mount your Terraform project: -v /path/to/project:/workspace" >&2
        exit 1
    fi

    # Check for Terraform files
    local tf_count
    tf_count=$(find "$dir" -maxdepth 1 -name '*.tf' | wc -l)

    if [[ "$tf_count" -eq 0 ]]; then
        echo -e "${YELLOW}⚠ No .tf files found in ${dir}${NC}" >&2
        echo "  Make sure you mounted your Terraform project correctly." >&2

        # Show what IS in the directory
        echo "  Contents of ${dir}:"
        ls -la "$dir" 2>/dev/null | head -20
        echo ""
    else
        echo -e "${GREEN}✓ Found ${tf_count} Terraform files in ${dir}${NC}"
    fi

    # Check for state
    if [[ -f "${dir}/terraform.tfstate" ]] || [[ -f "${dir}/.terraform/terraform.tfstate" ]]; then
        echo -e "${GREEN}✓ Local state file found${NC}"
    elif [[ -f "${dir}/.terraform/terraform.tfstate" ]]; then
        # Check if backend is configured (remote state)
        if grep -rq '"backend"' "${dir}/.terraform/" 2>/dev/null; then
            echo -e "${GREEN}✓ Remote backend configured${NC}"
        fi
    fi
}

# ── Show usage ───────────────────────────────────────────────────────────────
show_usage() {
    print_versions
    cat <<'EOF'
USAGE:
  docker run -it --rm \
    -v $(pwd)/my-project:/workspace \
    -v $HOME/.azure:/root/.azure \
    drift-fixer [COMMAND] [OPTIONS]

COMMANDS:
  fix, drift-fix            Run full drift detection & fix workflow
  plan                      Run terraform plan only (detect drift)
  lookup, az-lookup         Look up Azure resource IDs
  shell, bash               Drop into interactive bash shell
  validate                  Validate environment (auth, tools, workspace)
  --help, help              Show this help

FIX OPTIONS:
  --dir <path>              Terraform directory (default: /workspace)
  --execute                 Auto-execute generated fix commands
  --backup                  Back up state before changes (default: on)
  --target <addr>           Only analyse specific resource
  --var-file <file>         Pass tfvars file to plan
  --skip-azure-lookup       Skip Azure CLI resource lookups
  --tf-version-gte-15       Generate TF 1.5+ import blocks

AUTHENTICATION:
  Option A — Mount host credentials:
    -v $HOME/.azure:/root/.azure

  Option B — Service principal (env vars):
    -e AZURE_CLIENT_ID=xxx
    -e AZURE_CLIENT_SECRET=xxx
    -e AZURE_TENANT_ID=xxx
    -e AZURE_SUBSCRIPTION_ID=xxx

  Option C — Interactive login:
    docker run -it drift-fixer shell
    > az login

EXAMPLES:
  # Detect drift and generate fix scripts
  docker run -it --rm \
    -v $(pwd):/workspace \
    -v $HOME/.azure:/root/.azure \
    drift-fixer fix

  # Run with service principal
  docker run -it --rm \
    -v $(pwd):/workspace \
    -e AZURE_CLIENT_ID=$ARM_CLIENT_ID \
    -e AZURE_CLIENT_SECRET=$ARM_CLIENT_SECRET \
    -e AZURE_TENANT_ID=$ARM_TENANT_ID \
    -e AZURE_SUBSCRIPTION_ID=$ARM_SUBSCRIPTION_ID \
    drift-fixer fix --dir /workspace

  # Look up a resource
  docker run -it --rm \
    -v $HOME/.azure:/root/.azure \
    drift-fixer lookup --type azurerm_virtual_network --name my-vnet --rg my-rg

  # Interactive shell
  docker run -it --rm \
    -v $(pwd):/workspace \
    -v $HOME/.azure:/root/.azure \
    drift-fixer shell
EOF
}

# ── Configure Terraform backend credentials from env ─────────────────────────
setup_terraform_env() {
    # Map Azure SP env vars to Terraform's expected ARM_ vars if not already set
    export ARM_CLIENT_ID="${ARM_CLIENT_ID:-${AZURE_CLIENT_ID:-}}"
    export ARM_CLIENT_SECRET="${ARM_CLIENT_SECRET:-${AZURE_CLIENT_SECRET:-}}"
    export ARM_TENANT_ID="${ARM_TENANT_ID:-${AZURE_TENANT_ID:-}}"
    export ARM_SUBSCRIPTION_ID="${ARM_SUBSCRIPTION_ID:-${AZURE_SUBSCRIPTION_ID:-}}"

    # If using managed identity
    if [[ -n "${MSI_ENDPOINT:-}" || -n "${IDENTITY_ENDPOINT:-}" ]]; then
        export ARM_USE_MSI=true
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main dispatch
# ═══════════════════════════════════════════════════════════════════════════════

# If no arguments at all, show help
if [[ $# -eq 0 ]]; then
    show_usage
    exit 0
fi

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    # ── Full drift fix workflow ──────────────────────────────────────────
    fix|drift-fix|drift_fix|run)
        print_versions
        setup_terraform_env

        echo "── Environment Check ──────────────────────────────────"
        check_azure_auth || true

        # Determine workspace dir
        WORK_DIR="/workspace"
        for arg in "$@"; do
            if [[ "$prev_arg" == "--dir" || "$prev_arg" == "-d" ]]; then
                WORK_DIR="$arg"
            fi
            prev_arg="$arg"
        done

        check_workspace "$WORK_DIR"
        echo "───────────────────────────────────────────────────────"
        echo ""

        # Run the drift fixer
        exec "$DRIFT_FIXER" "$@"
        ;;

    # ── Plan only ────────────────────────────────────────────────────────
    plan)
        setup_terraform_env
        check_azure_auth || true
        echo "Running terraform plan..."
        exec terraform plan "$@"
        ;;

    # ── Azure resource lookup ────────────────────────────────────────────
    lookup|az-lookup|azure-lookup)
        check_azure_auth || { echo "Azure auth required for lookups"; exit 1; }
        exec "$AZ_LOOKUP" "$@"
        ;;

    # ── Interactive shell ────────────────────────────────────────────────
    shell|bash|sh)
        print_versions
        setup_terraform_env
        check_azure_auth || true
        echo ""
        echo -e "${GREEN}Dropping into interactive shell...${NC}"
        echo "  Available commands: drift-fixer, az-lookup, terraform, az, jq"
        echo "  Workspace: ${WORKSPACE}"
        echo ""
        exec /bin/bash "$@"
        ;;

    # ── Validate environment ─────────────────────────────────────────────
    validate|check)
        print_versions
        echo "── Tool Checks ────────────────────────────────────────"
        for tool in terraform az python3 jq git bash; do
            if command -v "$tool" &>/dev/null; then
                echo -e "  ${GREEN}✓${NC} $tool : $(command -v "$tool")"
            else
                echo -e "  ${RED}✗${NC} $tool : NOT FOUND"
            fi
        done
        echo ""
        echo "── Azure Authentication ───────────────────────────────"
        check_azure_auth || true
        echo ""
        echo "── Workspace ────────────────────────────────────────"
        check_workspace "${1:-/workspace}"
        echo ""
        echo "── Environment Variables ────────────────────────────"
        for var in ARM_CLIENT_ID ARM_TENANT_ID ARM_SUBSCRIPTION_ID \
                   AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID \
                   TF_VAR_environment TF_PLUGIN_CACHE_DIR; do
            if [[ -n "${!var:-}" ]]; then
                # Mask secrets
                if [[ "$var" == *SECRET* || "$var" == *PASSWORD* ]]; then
                    echo -e "  ${GREEN}✓${NC} ${var}=****"
                else
                    echo -e "  ${GREEN}✓${NC} ${var}=${!var}"
                fi
            else
                echo -e "  ${YELLOW}·${NC} ${var}=(not set)"
            fi
        done
        ;;

    # ── Terraform passthrough ────────────────────────────────────────────
    terraform|tf)
        setup_terraform_env
        exec terraform "$@"
        ;;

    # ── Azure CLI passthrough ────────────────────────────────────────────
    az)
        exec az "$@"
        ;;

    # ── Help ─────────────────────────────────────────────────────────────
    help|--help|-h)
        show_usage
        exit 0
        ;;

    # ── Unknown command: treat everything as args to drift_fixer ─────────
    *)
        # If first arg looks like a flag, pass everything to drift_fixer
        if [[ "$COMMAND" == -* ]]; then
            setup_terraform_env
            check_azure_auth || true
            exec "$DRIFT_FIXER" "$COMMAND" "$@"
        else
            echo -e "${RED}Unknown command: ${COMMAND}${NC}" >&2
            echo "Run with --help for usage information" >&2
            exit 1
        fi
        ;;
esac