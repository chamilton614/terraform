#!/usr/bin/env python3
"""
parse_drift.py

Parses terraform plan JSON + state JSON + Azure resource inventory
to produce:
  1. A human-readable drift report
  2. A machine-readable JSON with full details
  3. Shell scripts with terraform import / state rm commands
  4. (Optional) TF 1.5+ import blocks
"""

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

# ─────────────────────────────────────────────────────────────────────────────
# Azure resource type → ARM provider mapping (for az CLI lookups)
# ─────────────────────────────────────────────────────────────────────────────
AZURERM_TO_ARM = {
    "azurerm_resource_group":                   "Microsoft.Resources/resourceGroups",
    "azurerm_virtual_network":                  "Microsoft.Network/virtualNetworks",
    "azurerm_subnet":                           "Microsoft.Network/virtualNetworks/subnets",
    "azurerm_network_security_group":           "Microsoft.Network/networkSecurityGroups",
    "azurerm_network_security_rule":            "Microsoft.Network/networkSecurityGroups/securityRules",
    "azurerm_public_ip":                        "Microsoft.Network/publicIPAddresses",
    "azurerm_network_interface":                "Microsoft.Network/networkInterfaces",
    "azurerm_lb":                               "Microsoft.Network/loadBalancers",
    "azurerm_lb_rule":                          "Microsoft.Network/loadBalancers/loadBalancingRules",
    "azurerm_lb_backend_address_pool":          "Microsoft.Network/loadBalancers/backendAddressPools",
    "azurerm_lb_probe":                         "Microsoft.Network/loadBalancers/probes",
    "azurerm_lb_nat_rule":                      "Microsoft.Network/loadBalancers/inboundNatRules",
    "azurerm_application_gateway":              "Microsoft.Network/applicationGateways",
    "azurerm_route_table":                      "Microsoft.Network/routeTables",
    "azurerm_route":                            "Microsoft.Network/routeTables/routes",
    "azurerm_dns_zone":                         "Microsoft.Network/dnsZones",
    "azurerm_private_dns_zone":                 "Microsoft.Network/privateDnsZones",
    "azurerm_virtual_network_peering":          "Microsoft.Network/virtualNetworks/virtualNetworkPeerings",
    "azurerm_storage_account":                  "Microsoft.Storage/storageAccounts",
    "azurerm_storage_container":                "Microsoft.Storage/storageAccounts/blobServices/containers",
    "azurerm_key_vault":                        "Microsoft.KeyVault/vaults",
    "azurerm_key_vault_secret":                 "Microsoft.KeyVault/vaults/secrets",
    "azurerm_key_vault_key":                    "Microsoft.KeyVault/vaults/keys",
    "azurerm_key_vault_certificate":            "Microsoft.KeyVault/vaults/certificates",
    "azurerm_key_vault_access_policy":          "Microsoft.KeyVault/vaults/accessPolicies",
    "azurerm_linux_virtual_machine":            "Microsoft.Compute/virtualMachines",
    "azurerm_windows_virtual_machine":          "Microsoft.Compute/virtualMachines",
    "azurerm_virtual_machine":                  "Microsoft.Compute/virtualMachines",
    "azurerm_virtual_machine_scale_set":        "Microsoft.Compute/virtualMachineScaleSets",
    "azurerm_managed_disk":                     "Microsoft.Compute/disks",
    "azurerm_availability_set":                 "Microsoft.Compute/availabilitySets",
    "azurerm_image":                            "Microsoft.Compute/images",
    "azurerm_kubernetes_cluster":               "Microsoft.ContainerService/managedClusters",
    "azurerm_container_registry":               "Microsoft.ContainerRegistry/registries",
    "azurerm_container_group":                  "Microsoft.ContainerInstance/containerGroups",
    "azurerm_app_service_plan":                 "Microsoft.Web/serverfarms",
    "azurerm_service_plan":                     "Microsoft.Web/serverfarms",
    "azurerm_linux_web_app":                    "Microsoft.Web/sites",
    "azurerm_windows_web_app":                  "Microsoft.Web/sites",
    "azurerm_linux_function_app":               "Microsoft.Web/sites",
    "azurerm_windows_function_app":             "Microsoft.Web/sites",
    "azurerm_app_service":                      "Microsoft.Web/sites",
    "azurerm_function_app":                     "Microsoft.Web/sites",
    "azurerm_mssql_server":                     "Microsoft.Sql/servers",
    "azurerm_mssql_database":                   "Microsoft.Sql/servers/databases",
    "azurerm_mssql_firewall_rule":              "Microsoft.Sql/servers/firewallRules",
    "azurerm_cosmosdb_account":                 "Microsoft.DocumentDB/databaseAccounts",
    "azurerm_redis_cache":                      "Microsoft.Cache/redis",
    "azurerm_postgresql_server":                "Microsoft.DBforPostgreSQL/servers",
    "azurerm_postgresql_flexible_server":       "Microsoft.DBforPostgreSQL/flexibleServers",
    "azurerm_mysql_server":                     "Microsoft.DBforMySQL/servers",
    "azurerm_mysql_flexible_server":            "Microsoft.DBforMySQL/flexibleServers",
    "azurerm_log_analytics_workspace":          "Microsoft.OperationalInsights/workspaces",
    "azurerm_application_insights":             "Microsoft.Insights/components",
    "azurerm_monitor_action_group":             "Microsoft.Insights/actionGroups",
    "azurerm_monitor_metric_alert":             "Microsoft.Insights/metricAlerts",
    "azurerm_eventhub_namespace":               "Microsoft.EventHub/namespaces",
    "azurerm_eventhub":                         "Microsoft.EventHub/namespaces/eventHubs",
    "azurerm_servicebus_namespace":             "Microsoft.ServiceBus/namespaces",
    "azurerm_servicebus_queue":                 "Microsoft.ServiceBus/namespaces/queues",
    "azurerm_servicebus_topic":                 "Microsoft.ServiceBus/namespaces/topics",
    "azurerm_user_assigned_identity":           "Microsoft.ManagedIdentity/userAssignedIdentities",
    "azurerm_role_assignment":                  "Microsoft.Authorization/roleAssignments",
    "azurerm_policy_assignment":                "Microsoft.Authorization/policyAssignments",
    "azurerm_private_endpoint":                 "Microsoft.Network/privateEndpoints",
    "azurerm_private_dns_zone_virtual_network_link": "Microsoft.Network/privateDnsZones/virtualNetworkLinks",
    "azurerm_firewall":                         "Microsoft.Network/azureFirewalls",
    "azurerm_bastion_host":                     "Microsoft.Network/bastionHosts",
    "azurerm_nat_gateway":                      "Microsoft.Network/natGateways",
    "azurerm_data_factory":                     "Microsoft.DataFactory/factories",
    "azurerm_cognitive_account":                "Microsoft.CognitiveServices/accounts",
    "azurerm_api_management":                   "Microsoft.ApiManagement/service",
}


# ─────────────────────────────────────────────────────────────────────────────
# Data classes
# ─────────────────────────────────────────────────────────────────────────────
class DriftItem:
    """Represents a single drifted resource."""

    def __init__(self, address: str, resource_type: str, name: str,
                 actions: list[str], module: str = ""):
        self.address = address
        self.resource_type = resource_type
        self.name = name
        self.actions = actions          # e.g. ["update"], ["delete","create"]
        self.module = module
        self.before: dict = {}
        self.after: dict = {}
        self.diff_attributes: list[dict] = []
        self.state_id: str = ""         # current ID in terraform state
        self.azure_id: str = ""         # actual Azure resource ID found via az CLI
        self.fix_strategy: str = ""     # "import", "state_rm_import", "recreate", etc.
        self.import_cmd: str = ""
        self.state_rm_cmd: str = ""
        self.notes: list[str] = []

    @property
    def action_label(self) -> str:
        mapping = {
            ("no-op",):          "NO CHANGE",
            ("create",):         "CREATE (missing from state/Azure)",
            ("read",):           "READ",
            ("update",):         "UPDATE IN-PLACE (drift)",
            ("delete",):         "DELETE",
            ("delete", "create"): "REPLACE (destroy then create)",
            ("create", "delete"): "REPLACE (create then destroy)",
        }
        return mapping.get(tuple(self.actions), " | ".join(self.actions))

    def to_dict(self) -> dict:
        return {
            "address": self.address,
            "resource_type": self.resource_type,
            "name": self.name,
            "module": self.module,
            "actions": self.actions,
            "action_label": self.action_label,
            "state_id": self.state_id,
            "azure_id": self.azure_id,
            "fix_strategy": self.fix_strategy,
            "import_cmd": self.import_cmd,
            "state_rm_cmd": self.state_rm_cmd,
            "diff_attributes": self.diff_attributes,
            "notes": self.notes,
        }


# ─────────────────────────────────────────────────────────────────────────────
# Parsing functions
# ─────────────────────────────────────────────────────────────────────────────
def parse_plan(plan_path: str) -> list[DriftItem]:
    """Parse the terraform show -json plan output."""
    with open(plan_path) as f:
        plan = json.load(f)

    items = []
    for rc in plan.get("resource_changes", []):
        actions = rc.get("change", {}).get("actions", [])

        # Skip no-ops
        if actions == ["no-op"] or actions == ["read"]:
            continue

        # Extract module path
        address = rc.get("address", "")
        module_addr = rc.get("module_address", "")

        item = DriftItem(
            address=address,
            resource_type=rc.get("type", ""),
            name=rc.get("name", ""),
            actions=actions,
            module=module_addr,
        )

        change = rc.get("change", {})
        item.before = change.get("before") or {}
        item.after = change.get("after") or {}

        # Compute attribute-level diffs
        item.diff_attributes = compute_attribute_diff(item.before, item.after)

        items.append(item)

    return items


def compute_attribute_diff(before: dict, after: dict) -> list[dict]:
    """Compare before/after dicts and return list of changed attributes."""
    diffs = []
    all_keys = set(list(before.keys()) + list(after.keys()))

    for key in sorted(all_keys):
        # Skip computed / internal fields
        if key in ("id", "timeouts"):
            continue

        bval = before.get(key, "<not set>")
        aval = after.get(key, "<not set>")

        if bval != aval:
            # Truncate long values for readability
            bval_str = _truncate(bval)
            aval_str = _truncate(aval)
            diffs.append({
                "attribute": key,
                "before": bval_str,
                "after": aval_str,
            })

    return diffs


def _truncate(val: Any, max_len: int = 200) -> str:
    s = str(val)
    return s if len(s) <= max_len else s[:max_len] + "..."


# ─────────────────────────────────────────────────────────────────────────────
# State investigation
# ─────────────────────────────────────────────────────────────────────────────
def load_state(state_path: str) -> dict:
    """Load terraform state JSON."""
    with open(state_path) as f:
        return json.load(f)


def build_state_id_map(state: dict) -> dict[str, str]:
    """
    Build a map of resource_address → Azure resource ID from state.
    Handles modules, count, and for_each.
    """
    id_map = {}

    for resource in state.get("resources", []):
        module = resource.get("module", "")
        res_type = resource.get("type", "")
        res_name = resource.get("name", "")
        res_mode = resource.get("mode", "managed")

        if res_mode != "managed":
            continue

        for instance in resource.get("instances", []):
            attrs = instance.get("attributes", {})
            resource_id = attrs.get("id", "")

            # Build the full address
            index_key = instance.get("index_key")
            if module:
                base_addr = f"{module}.{res_type}.{res_name}"
            else:
                base_addr = f"{res_type}.{res_name}"

            if index_key is not None:
                if isinstance(index_key, int):
                    addr = f'{base_addr}[{index_key}]'
                else:
                    addr = f'{base_addr}["{index_key}"]'
            else:
                addr = base_addr

            id_map[addr] = resource_id

    return id_map


def enrich_from_state_show(items: list[DriftItem], state_show_dir: str):
    """
    Parse individual `terraform state show` outputs to get detailed info.
    Falls back to state JSON if files are missing.
    """
    if not os.path.isdir(state_show_dir):
        return

    for item in items:
        safe_name = item.address.replace("/", "_").replace(":", "_") \
                                .replace("[", "_").replace("]", "_") \
                                .replace('"', "_")
        show_file = os.path.join(state_show_dir, f"{safe_name}.txt")

        if os.path.isfile(show_file):
            with open(show_file) as f:
                content = f.read()

            # Extract the id = "..." line
            id_match = re.search(r'^\s+id\s+=\s+"(.+)"', content, re.MULTILINE)
            if id_match and not item.state_id:
                item.state_id = id_match.group(1)


# ─────────────────────────────────────────────────────────────────────────────
# Azure CLI correlation
# ─────────────────────────────────────────────────────────────────────────────
def load_azure_resources(azure_json_path: str) -> list[dict]:
    """Load the az resource list output."""
    with open(azure_json_path) as f:
        return json.load(f)


def find_azure_resource(item: DriftItem, azure_resources: list[dict],
                        state_id_map: dict[str, str]) -> str:
    """
    Try to find the actual Azure resource ID for a drifted resource.

    Strategy:
      1. Check if the state already has an ID (it might just need refresh)
      2. Match by ARM resource type + name in Azure inventory
      3. Match by resource name pattern
    """
    # Strategy 1: Use state ID if present
    state_id = state_id_map.get(item.address, "")
    if state_id:
        item.state_id = state_id

    # Strategy 2: Look up before.id (the plan knows the current ID)
    before_id = item.before.get("id", "")
    if before_id:
        return before_id

    # Strategy 3: Search Azure resource inventory
    arm_type = AZURERM_TO_ARM.get(item.resource_type, "")
    if arm_type and azure_resources:
        # Try matching by type + name
        resource_name = _guess_resource_name(item)
        for az_res in azure_resources:
            az_type = az_res.get("type", "")
            az_name = az_res.get("name", "")
            if az_type.lower() == arm_type.lower():
                if resource_name and az_name.lower() == resource_name.lower():
                    return az_res.get("id", "")

        # Broader match: just by type (if only one exists)
        type_matches = [
            r for r in azure_resources
            if r.get("type", "").lower() == arm_type.lower()
        ]
        if len(type_matches) == 1:
            return type_matches[0].get("id", "")

    # Strategy 4: Return state ID as best guess
    return state_id


def _guess_resource_name(item: DriftItem) -> str:
    """Try to determine the Azure resource name from plan attributes."""
    # Common attribute names that hold the Azure resource name
    for attr in ("name", "server_name", "account_name", "vault_name",
                 "workspace_name", "cluster_name", "registry_name",
                 "namespace_name", "factory_name"):
        name = item.after.get(attr) or item.before.get(attr)
        if name:
            return name
    return ""


# ─────────────────────────────────────────────────────────────────────────────
# Fix strategy determination
# ─────────────────────────────────────────────────────────────────────────────
def determine_fix_strategy(item: DriftItem):
    """
    Decide how to fix each drifted resource.

    Strategies:
      - "refresh"           → Just run terraform apply -refresh-only
      - "import"            → Resource missing from state, import it
      - "state_rm_import"   → State has wrong ID, remove and re-import
      - "recreate"          → Resource must be destroyed and recreated
      - "manual"            → Needs manual intervention
      - "accept_drift"      → Apply terraform to push desired config to Azure
    """
    actions = tuple(item.actions)

    if actions == ("update",):
        # In-place update drift.  Two options:
        # a) If you want Azure's current values → state_rm + import
        # b) If you want Terraform's config values → terraform apply
        if item.state_id and item.azure_id and item.state_id != item.azure_id:
            item.fix_strategy = "state_rm_import"
            item.notes.append(
                "State ID differs from Azure ID. Will remove from state and re-import.")
        elif item.azure_id:
            item.fix_strategy = "state_rm_import"
            item.notes.append(
                "Attributes drifted. Will re-import to sync state with Azure reality.")
        else:
            item.fix_strategy = "accept_drift"
            item.notes.append(
                "Could not find Azure ID. Run 'terraform apply' to push config, "
                "or manually provide the Azure resource ID for import.")

    elif actions == ("create",):
        # Resource needs to be created — either missing from state or Azure
        if item.azure_id:
            item.fix_strategy = "import"
            item.notes.append(
                "Resource exists in Azure but not in state. Will import.")
        else:
            item.fix_strategy = "manual"
            item.notes.append(
                "Resource will be created. If it already exists in Azure, "
                "find its ID and import it. Otherwise, 'terraform apply' will create it.")

    elif actions in [("delete", "create"), ("create", "delete")]:
        # Replacement needed
        if item.azure_id:
            item.fix_strategy = "state_rm_import"
            item.notes.append(
                "Resource needs replacement. Re-importing may fix if the "
                "underlying resource hasn't actually changed.")
        else:
            item.fix_strategy = "recreate"
            item.notes.append(
                "Resource will be replaced. Review if this is acceptable "
                "or find the Azure ID to import.")

    elif actions == ("delete",):
        item.fix_strategy = "state_rm"
        item.notes.append(
            "Resource is in state but not in config. "
            "Will be removed from state (not deleted from Azure).")

    else:
        item.fix_strategy = "manual"
        item.notes.append(f"Unhandled action combination: {actions}")

    # Generate commands
    _generate_commands(item)


def _generate_commands(item: DriftItem):
    """Generate the actual terraform CLI commands."""
    addr = item.address
    azure_id = item.azure_id or item.state_id

    if item.fix_strategy == "import":
        if azure_id:
            item.import_cmd = f'terraform import \'{addr}\' \'{azure_id}\''
        else:
            item.import_cmd = (
                f'# TODO: Find the Azure resource ID and run:\n'
                f'# terraform import \'{addr}\' <AZURE_RESOURCE_ID>'
            )

    elif item.fix_strategy == "state_rm_import":
        item.state_rm_cmd = f'terraform state rm \'{addr}\''
        if azure_id:
            item.import_cmd = f'terraform import \'{addr}\' \'{azure_id}\''
        else:
            item.import_cmd = (
                f'# TODO: Find the Azure resource ID and run:\n'
                f'# terraform import \'{addr}\' <AZURE_RESOURCE_ID>'
            )

    elif item.fix_strategy == "state_rm":
        item.state_rm_cmd = f'terraform state rm \'{addr}\''

    elif item.fix_strategy == "accept_drift":
        item.notes.append("Run: terraform apply -target='" + addr + "'")

    elif item.fix_strategy == "recreate":
        item.notes.append(
            f"Review plan output. If replacement is unacceptable, "
            f"find the Azure resource ID and import it:\n"
            f"  terraform state rm '{addr}'\n"
            f"  terraform import '{addr}' <AZURE_RESOURCE_ID>"
        )


# ─────────────────────────────────────────────────────────────────────────────
# Report generation
# ─────────────────────────────────────────────────────────────────────────────
def generate_report(items: list[DriftItem], output_dir: str):
    """Generate all output files."""

    # ── 1. Human-readable report ─────────────────────────────────────────
    report_lines = []
    report_lines.append("TERRAFORM DRIFT ANALYSIS REPORT")
    report_lines.append("=" * 70)
    report_lines.append(f"Total drifted resources: {len(items)}")
    report_lines.append("")

    # Summary by action type
    by_action = defaultdict(list)
    for item in items:
        by_action[item.action_label].append(item)

    report_lines.append("SUMMARY BY ACTION TYPE:")
    report_lines.append("-" * 40)
    for action, group in sorted(by_action.items()):
        report_lines.append(f"  {action}: {len(group)}")
    report_lines.append("")

    # Summary by fix strategy
    by_strategy = defaultdict(list)
    for item in items:
        by_strategy[item.fix_strategy].append(item)

    report_lines.append("SUMMARY BY FIX STRATEGY:")
    report_lines.append("-" * 40)
    strategy_descriptions = {
        "import":           "Import into state (resource exists in Azure, not in state)",
        "state_rm_import":  "Remove from state + re-import (state out of sync)",
        "state_rm":         "Remove from state only",
        "accept_drift":     "Run terraform apply to push config to Azure",
        "recreate":         "Resource will be replaced (review carefully!)",
        "manual":           "Requires manual intervention",
    }
    for strategy, group in sorted(by_strategy.items()):
        desc = strategy_descriptions.get(strategy, strategy)
        report_lines.append(f"  [{len(group)}] {strategy}: {desc}")
    report_lines.append("")

    # Detailed per-resource report
    report_lines.append("DETAILED RESOURCE REPORT:")
    report_lines.append("=" * 70)

    for i, item in enumerate(items, 1):
        report_lines.append(f"\n{'─' * 70}")
        report_lines.append(f"Resource #{i}: {item.address}")
        report_lines.append(f"{'─' * 70}")
        report_lines.append(f"  Type:          {item.resource_type}")
        report_lines.append(f"  Name:          {item.name}")
        if item.module:
            report_lines.append(f"  Module:        {item.module}")
        report_lines.append(f"  Action:        {item.action_label}")
        report_lines.append(f"  Fix Strategy:  {item.fix_strategy}")
        report_lines.append(f"  State ID:      {item.state_id or 'N/A'}")
        report_lines.append(f"  Azure ID:      {item.azure_id or 'NOT FOUND'}")

        if item.diff_attributes:
            report_lines.append(f"\n  Changed Attributes ({len(item.diff_attributes)}):")
            for diff in item.diff_attributes[:20]:  # Limit to 20 attrs
                report_lines.append(f"    • {diff['attribute']}:")
                report_lines.append(f"        before: {diff['before']}")
                report_lines.append(f"        after:  {diff['after']}")
            if len(item.diff_attributes) > 20:
                report_lines.append(
                    f"    ... and {len(item.diff_attributes) - 20} more")

        if item.import_cmd:
            report_lines.append(f"\n  Fix Command(s):")
            if item.state_rm_cmd:
                report_lines.append(f"    $ {item.state_rm_cmd}")
            report_lines.append(f"    $ {item.import_cmd}")

        for note in item.notes:
            report_lines.append(f"\n  ℹ️  {note}")

    report_path = os.path.join(output_dir, "drift_report.txt")
    with open(report_path, "w") as f:
        f.write("\n".join(report_lines))

    # ── 2. Machine-readable JSON ─────────────────────────────────────────
    details = {
        "total_drifted": len(items),
        "by_action": {k: len(v) for k, v in by_action.items()},
        "by_strategy": {k: len(v) for k, v in by_strategy.items()},
        "resources": [item.to_dict() for item in items],
    }
    details_path = os.path.join(output_dir, "drift_details.json")
    with open(details_path, "w") as f:
        json.dump(details, f, indent=2)

    # ── 3. Fix shell script (direct execution) ──────────────────────────
    fix_lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        "# ═══════════════════════════════════════════════════════════════",
        "# TERRAFORM STATE FIX SCRIPT",
        f"# Generated by drift_fixer - {len(items)} resources to fix",
        "# ═══════════════════════════════════════════════════════════════",
        "",
        "# Back up state first",
        'echo "Backing up current state..."',
        "terraform state pull > terraform.tfstate.backup.$(date +%s)",
        "",
    ]

    # Group commands by strategy for cleaner output
    # Order: state_rm first, then imports
    state_rm_cmds = []
    import_cmds = []

    for item in items:
        if item.state_rm_cmd:
            state_rm_cmds.append((item.address, item.state_rm_cmd))
        if item.import_cmd and not item.import_cmd.startswith("#"):
            import_cmds.append((item.address, item.import_cmd))

    if state_rm_cmds:
        fix_lines.append("# ── Phase 1: Remove stale/incorrect entries from state ────────")
        for addr, cmd in state_rm_cmds:
            fix_lines.append(f"echo 'Removing: {addr}'")
            fix_lines.append(cmd)
            fix_lines.append("")

    if import_cmds:
        fix_lines.append("")
        fix_lines.append("# ── Phase 2: Import resources into state ──────────────────────")
        for addr, cmd in import_cmds:
            fix_lines.append(f"echo 'Importing: {addr}'")
            fix_lines.append(cmd)
            fix_lines.append("")

    fix_lines.extend([
        "",
        "# ── Phase 3: Verify ────────────────────────────────────────────",
        'echo ""',
        'echo "Running terraform plan to verify fixes..."',
        "terraform plan -detailed-exitcode || true",
        'echo "Done! Review the plan output above."',
    ])

    fix_path = os.path.join(output_dir, "fix_state.sh")
    with open(fix_path, "w") as f:
        f.write("\n".join(fix_lines))
    os.chmod(fix_path, 0o755)

    # ── 4. Safe fix script (with confirmations) ─────────────────────────
    safe_lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        "# Safe version — asks for confirmation before each operation",
        "",
        "confirm() {",
        '  echo ""',
        '  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"',
        '  echo "NEXT: $1"',
        '  echo "CMD:  $2"',
        '  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"',
        '  read -p "Execute? (y/N/q) " answer',
        '  case "$answer" in',
        '    y|Y) eval "$2" ;;',
        '    q|Q) echo "Quitting."; exit 0 ;;',
        '    *)   echo "Skipped." ;;',
        '  esac',
        "}",
        "",
        "terraform state pull > terraform.tfstate.backup.$(date +%s)",
        'echo "State backed up."',
        "",
    ]

    for item in items:
        if item.state_rm_cmd:
            safe_lines.append(
                f"confirm 'Remove {item.address} from state' "
                f"'{item.state_rm_cmd}'"
            )
        if item.import_cmd and not item.import_cmd.startswith("#"):
            safe_lines.append(
                f"confirm 'Import {item.address}' "
                f"'{item.import_cmd}'"
            )

    safe_lines.extend([
        "",
        'echo ""',
        'echo "Running verification plan..."',
        "terraform plan || true",
    ])

    safe_path = os.path.join(output_dir, "fix_state_safe.sh")
    with open(safe_path, "w") as f:
        f.write("\n".join(safe_lines))
    os.chmod(safe_path, 0o755)

    # ── 5. Manual TODO list for items that couldn't be auto-resolved ────
    manual_items = [i for i in items if i.fix_strategy in ("manual", "recreate")
                    or not i.azure_id]
    if manual_items:
        todo_lines = [
            "MANUAL ACTIONS REQUIRED",
            "=" * 50,
            "",
            "The following resources could not be automatically resolved.",
            "You need to find their Azure resource IDs manually.",
            "",
            "Useful Azure CLI commands:",
            "  az resource list --resource-group <RG_NAME> -o table",
            "  az resource list --name <RESOURCE_NAME> -o json",
            "  az resource show --ids <RESOURCE_ID>",
            "",
        ]
        for item in manual_items:
            todo_lines.append(f"─── {item.address} ───")
            todo_lines.append(f"  Type: {item.resource_type}")
            todo_lines.append(f"  Action: {item.action_label}")
            arm_type = AZURERM_TO_ARM.get(item.resource_type, "unknown")
            todo_lines.append(f"  ARM Type: {arm_type}")
            resource_name = _guess_resource_name(item)
            if resource_name:
                todo_lines.append(f"  Probable Azure Name: {resource_name}")
                todo_lines.append(
                    f"  Try: az resource list --name '{resource_name}' "
                    f"--resource-type '{arm_type}' -o json"
                )
            todo_lines.append(f"  Then run:")
            todo_lines.append(f"    terraform import '{item.address}' <AZURE_RESOURCE_ID>")
            todo_lines.append("")

        todo_path = os.path.join(output_dir, "manual_todo.txt")
        with open(todo_path, "w") as f:
            f.write("\n".join(todo_lines))


def generate_import_blocks(items: list[DriftItem], output_dir: str):
    """Generate Terraform 1.5+ import blocks."""
    lines = [
        "# ═══════════════════════════════════════════════════════════════",
        "# Terraform 1.5+ Import Blocks",
        "# Add this file to your Terraform configuration, then run:",
        "#   terraform plan   (to preview)",
        "#   terraform apply  (to execute imports)",
        "# ═══════════════════════════════════════════════════════════════",
        "",
    ]

    for item in items:
        if item.fix_strategy not in ("import", "state_rm_import"):
            continue

        azure_id = item.azure_id or item.state_id
        if not azure_id:
            lines.append(f"# TODO: {item.address} — Azure ID not found")
            lines.append(f"# import {{")
            lines.append(f"#   to = {item.address}")
            lines.append(f"#   id = \"<AZURE_RESOURCE_ID>\"")
            lines.append(f"# }}")
        else:
            lines.append(f"import {{")
            lines.append(f"  to = {item.address}")
            lines.append(f'  id = "{azure_id}"')
            lines.append(f"}}")
        lines.append("")

    import_path = os.path.join(output_dir, "imports.tf")
    with open(import_path, "w") as f:
        f.write("\n".join(lines))


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Parse Terraform plan drift and generate fix commands"
    )
    parser.add_argument("--plan-json", required=True,
                        help="Path to terraform show -json output")
    parser.add_argument("--state-json", required=True,
                        help="Path to terraform state pull output")
    parser.add_argument("--state-list", required=True,
                        help="Path to terraform state list output")
    parser.add_argument("--azure-json", required=True,
                        help="Path to az resource list JSON output")
    parser.add_argument("--output-dir", required=True,
                        help="Directory to write output files")
    parser.add_argument("--state-show-dir", default="",
                        help="Directory containing terraform state show outputs")
    parser.add_argument("--import-blocks", action="store_true",
                        help="Also generate TF 1.5+ import blocks")

    args = parser.parse_args()

    # ── Parse plan ───────────────────────────────────────────────────────
    print(f"Parsing plan from {args.plan_json}...")
    items = parse_plan(args.plan_json)

    if not items:
        print("No drifted resources found in plan!")
        # Still generate empty report
        with open(os.path.join(args.output_dir, "drift_report.txt"), "w") as f:
            f.write("No drift detected.\n")
        return

    print(f"Found {len(items)} drifted resources")

    # ── Load state ───────────────────────────────────────────────────────
    print(f"Loading state from {args.state_json}...")
    state = load_state(args.state_json)
    state_id_map = build_state_id_map(state)
    print(f"  State contains {len(state_id_map)} managed resources")

    # Enrich with state ID info
    for item in items:
        if item.address in state_id_map:
            item.state_id = state_id_map[item.address]

    # Enrich with state show details
    if args.state_show_dir:
        enrich_from_state_show(items, args.state_show_dir)

    # ── Azure lookup ─────────────────────────────────────────────────────
    print(f"Loading Azure resource inventory from {args.azure_json}...")
    azure_resources = load_azure_resources(args.azure_json)
    print(f"  Azure inventory has {len(azure_resources)} resources")

    for item in items:
        item.azure_id = find_azure_resource(item, azure_resources, state_id_map)

    # ── Determine fix strategies ─────────────────────────────────────────
    print("Determining fix strategies...")
    for item in items:
        determine_fix_strategy(item)

    # ── Generate outputs ─────────────────────────────────────────────────
    print(f"Generating reports in {args.output_dir}...")
    os.makedirs(args.output_dir, exist_ok=True)
    generate_report(items, args.output_dir)

    if args.import_blocks:
        generate_import_blocks(items, args.output_dir)

    # ── Print summary ────────────────────────────────────────────────────
    print("\n" + "=" * 50)
    print("QUICK SUMMARY")
    print("=" * 50)
    by_strategy = defaultdict(int)
    for item in items:
        by_strategy[item.fix_strategy] += 1

    for strategy, count in sorted(by_strategy.items()):
        print(f"  {strategy:20s}: {count}")

    auto_fixable = sum(1 for i in items if i.azure_id and
                       i.fix_strategy in ("import", "state_rm_import"))
    print(f"\n  Auto-fixable: {auto_fixable}/{len(items)}")
    if auto_fixable < len(items):
        print(f"  Manual review needed: {len(items) - auto_fixable}")
        print(f"  See: {args.output_dir}/manual_todo.txt")


if __name__ == "__main__":
    main()