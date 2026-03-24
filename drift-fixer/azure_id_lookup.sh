#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# azure_id_lookup.sh
#
# Standalone helper to find Azure resource IDs for terraform import.
# Useful when the automated lookup fails and you need to find IDs manually.
#
# Usage:
#   ./azure_id_lookup.sh --type azurerm_virtual_network --name my-vnet --rg my-rg
#   ./azure_id_lookup.sh --search "my-resource"
#   ./azure_id_lookup.sh --list-rg my-resource-group
#   ./azure_id_lookup.sh --from-state ./state.json --address "module.net.azurerm_subnet.main"
###############################################################################

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

# ── Terraform type → ARM type mapping ────────────────────────────────────────
declare -A TYPE_MAP=(
  ["azurerm_resource_group"]="Microsoft.Resources/resourceGroups"
  ["azurerm_virtual_network"]="Microsoft.Network/virtualNetworks"
  ["azurerm_subnet"]="Microsoft.Network/virtualNetworks/subnets"
  ["azurerm_network_security_group"]="Microsoft.Network/networkSecurityGroups"
  ["azurerm_public_ip"]="Microsoft.Network/publicIPAddresses"
  ["azurerm_network_interface"]="Microsoft.Network/networkInterfaces"
  ["azurerm_lb"]="Microsoft.Network/loadBalancers"
  ["azurerm_storage_account"]="Microsoft.Storage/storageAccounts"
  ["azurerm_key_vault"]="Microsoft.KeyVault/vaults"
  ["azurerm_linux_virtual_machine"]="Microsoft.Compute/virtualMachines"
  ["azurerm_windows_virtual_machine"]="Microsoft.Compute/virtualMachines"
  ["azurerm_managed_disk"]="Microsoft.Compute/disks"
  ["azurerm_kubernetes_cluster"]="Microsoft.ContainerService/managedClusters"
  ["azurerm_container_registry"]="Microsoft.ContainerRegistry/registries"
  ["azurerm_app_service_plan"]="Microsoft.Web/serverfarms"
  ["azurerm_service_plan"]="Microsoft.Web/serverfarms"
  ["azurerm_linux_web_app"]="Microsoft.Web/sites"
  ["azurerm_mssql_server"]="Microsoft.Sql/servers"
  ["azurerm_mssql_database"]="Microsoft.Sql/servers/databases"
  ["azurerm_cosmosdb_account"]="Microsoft.DocumentDB/databaseAccounts"
  ["azurerm_log_analytics_workspace"]="Microsoft.OperationalInsights/workspaces"
  ["azurerm_application_insights"]="Microsoft.Insights/components"
  ["azurerm_user_assigned_identity"]="Microsoft.ManagedIdentity/userAssignedIdentities"
  ["azurerm_private_endpoint"]="Microsoft.Network/privateEndpoints"
  ["azurerm_postgresql_flexible_server"]="Microsoft.DBforPostgreSQL/flexibleServers"
)

lookup_by_type_and_name() {
  local tf_type="$1"
  local name="$2"
  local rg="${3:-}"

  local arm_type="${TYPE_MAP[$tf_type]:-}"
  if [[ -z "$arm_type" ]]; then
    echo -e "${YELLOW}Unknown TF type: ${tf_type}${NC}" >&2
    echo -e "Searching by name only..." >&2
    if [[ -n "$rg" ]]; then
      az resource list --resource-group "$rg" --name "$name" -o json | jq -r '.[].id'
    else
      az resource list --name "$name" -o json | jq -r '.[].id'
    fi
    return
  fi

  echo -e "${CYAN}Searching for: ${arm_type} named '${name}'${NC}" >&2

  local args=(--resource-type "$arm_type" --name "$name")
  [[ -n "$rg" ]] && args+=(--resource-group "$rg")

  local result
  result="$(az resource list "${args[@]}" -o json 2>/dev/null)"

  local count
  count="$(echo "$result" | jq length)"

  if [[ "$count" -eq 0 ]]; then
    echo -e "${RED}No resources found.${NC}" >&2
    echo -e "Try: az resource list --name '$name' -o table" >&2
    return 1
  elif [[ "$count" -eq 1 ]]; then
    local id
    id="$(echo "$result" | jq -r '.[0].id')"
    echo -e "${GREEN}Found:${NC}" >&2
    echo "$id"
  else
    echo -e "${YELLOW}Multiple matches found:${NC}" >&2
    echo "$result" | jq -r '.[] | "  \(.id)"'
  fi
}

search_by_name() {
  local search="$1"
  echo -e "${CYAN}Searching all Azure resources matching: ${search}${NC}" >&2

  az resource list --query "[?contains(name, '${search}')]" -o table
  echo ""
  echo "Resource IDs:"
  az resource list --query "[?contains(name, '${search}')].id" -o tsv
}

list_resource_group() {
  local rg="$1"
  echo -e "${CYAN}All resources in resource group: ${rg}${NC}" >&2
  az resource list --resource-group "$rg" -o table
  echo ""
  echo -e "${CYAN}Resource IDs:${NC}" >&2
  az resource list --resource-group "$rg" --query '[].{type:type, name:name, id:id}' -o json | \
    jq -r '.[] | "\(.type) | \(.name) | \(.id)"' | column -t -s'|'
}

from_state() {
  local state_file="$1"
  local address="$2"

  echo -e "${CYAN}Looking up ${address} in state file...${NC}" >&2

  local id
  id="$(jq -r --arg addr "$address" '
    .resources[] |
    select(
      (.module // "") + "." + .type + "." + .name == $addr or
      .type + "." + .name == $addr
    ) |
    .instances[].attributes.id
  ' "$state_file" 2>/dev/null)"

  if [[ -n "$id" && "$id" != "null" ]]; then
    echo -e "${GREEN}Found in state:${NC}" >&2
    echo "$id"

    # Verify it still exists in Azure
    if az resource show --ids "$id" &>/dev/null; then
      echo -e "${GREEN}✓ Verified: resource exists in Azure${NC}" >&2
    else
      echo -e "${RED}✗ Warning: resource NOT found in Azure!${NC}" >&2
    fi
  else
    echo -e "${RED}Not found in state file${NC}" >&2
    return 1
  fi
}

# Generate terraform import command
gen_import() {
  local tf_type="$1"
  local name="$2"
  local rg="${3:-}"

  local azure_id
  azure_id="$(lookup_by_type_and_name "$tf_type" "$name" "$rg")"

  if [[ -n "$azure_id" ]]; then
    echo ""
    echo -e "${GREEN}Terraform import command:${NC}"
    echo "  terraform import '${tf_type}.${name}' '${azure_id}'"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────
case "${1:-}" in
  --type)
    lookup_by_type_and_name "${2:-}" "${4:-}" "${6:-}"
    ;;
  --search)
    search_by_name "${2:-}"
    ;;
  --list-rg)
    list_resource_group "${2:-}"
    ;;
  --from-state)
    from_state "${2:-}" "${4:-}"
    ;;
  --gen-import)
    gen_import "${2:-}" "${4:-}" "${6:-}"
    ;;
  *)
    cat <<EOF
Usage:
  $(basename "$0") --type <tf_type> --name <resource_name> [--rg <resource_group>]
  $(basename "$0") --search <name_pattern>
  $(basename "$0") --list-rg <resource_group_name>
  $(basename "$0") --from-state <state.json> --address <terraform_address>
  $(basename "$0") --gen-import <tf_type> --name <name> [--rg <rg>]

Examples:
  $(basename "$0") --type azurerm_virtual_network --name my-vnet --rg my-rg
  $(basename "$0") --search "prod-"
  $(basename "$0") --list-rg production-rg
  $(basename "$0") --from-state state.json --address "azurerm_resource_group.main"
  $(basename "$0") --gen-import azurerm_storage_account --name mystorageacct
EOF
    ;;
esac