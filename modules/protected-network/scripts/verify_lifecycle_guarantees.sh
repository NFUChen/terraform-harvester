#!/usr/bin/env bash
# Reproducible, read-only proof of protected-network's lifecycle guarantees:
#   1. prevent_destroy rejects `terraform plan -destroy` against an existing
#      network.
#   2. ignore_changes suppresses vlan_id and cluster_network_name drift while
#      a known mutable description difference proves Terraform actually
#      compared the fabricated resource state.
#
# The script never applies or destroys infrastructure. It performs a live,
# read-only ClusterNetwork data-source lookup, so it requires cluster access.
#
# Usage:
#   scripts/verify_lifecycle_guarantees.sh <cluster_network_name> <kubeconfig_path>

set -euo pipefail

CLUSTER_NETWORK_NAME="${1:?usage: verify_lifecycle_guarantees.sh <cluster_network_name> <kubeconfig_path>}"
KUBECONFIG_PATH="${2:?usage: verify_lifecycle_guarantees.sh <cluster_network_name> <kubeconfig_path>}"

if [[ ! "${CLUSTER_NETWORK_NAME}" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]]; then
  echo "cluster_network_name must be a Kubernetes DNS-1123 label" >&2
  exit 1
fi
if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
  echo "kubeconfig does not exist: ${KUBECONFIG_PATH}" >&2
  exit 1
fi

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
ln -s "${MODULE_DIR}" "${WORKDIR}/module"

cat > "${WORKDIR}/main.tf" <<'EOF'
terraform {
  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "= 1.9.0"
    }
  }
}

variable "kubeconfig_path" { type = string }
variable "cluster_network_name" { type = string }

provider "harvester" {
  kubeconfig = var.kubeconfig_path
}

module "net" {
  source = "./module"

  namespace            = "harvester-public"
  cluster_network_name = var.cluster_network_name

  networks = {
    "verify-lifecycle-guard" = {
      vlan_id     = 200
      description = "mutable-positive-control"
    }
  }
}
EOF

python3 - "${WORKDIR}" "${KUBECONFIG_PATH}" "${CLUSTER_NETWORK_NAME}" <<'PY'
import json, os, sys
workdir, kubeconfig, cluster_network = sys.argv[1:]
with open(os.path.join(workdir, "terraform.auto.tfvars.json"), "w") as f:
    json.dump({
        "kubeconfig_path": kubeconfig,
        "cluster_network_name": cluster_network,
    }, f)

state = {
    "version": 4,
    "terraform_version": "1.15.4",
    "serial": 1,
    "lineage": "22222222-2222-2222-2222-222222222222",
    "outputs": {},
    "resources": [{
        "module": "module.net",
        "mode": "managed",
        "type": "harvester_network",
        "name": "this",
        "provider": 'provider["registry.terraform.io/harvester/harvester"]',
        "instances": [{
            "index_key": "verify-lifecycle-guard",
            "schema_version": 0,
            "attributes": {
                "id": "harvester-public/verify-lifecycle-guard",
                "name": "verify-lifecycle-guard",
                "namespace": "harvester-public",
                "vlan_id": 100,
                # Deliberately differs from config. It need not exist because
                # ignore_changes must retain this state value without a lookup.
                "cluster_network_name": "legacy-network",
                "route_mode": "auto",
                "route_cidr": "",
                "route_gateway": "",
                "route_dhcp_server_ip": "",
                "route_connectivity": "",
                "config": "{}",
                # Deliberately mutable so the plan has a positive-control diff.
                "description": None,
                "labels": {},
                "tags": {},
                "message": "",
                "state": "active",
                "timeouts": {
                    "create": "5m", "default": None, "delete": "10m",
                    "read": "2m", "update": "5m",
                },
            },
            "sensitive_attributes": [],
        }],
    }],
    "check_results": None,
}
with open(os.path.join(workdir, "terraform.tfstate"), "w") as f:
    json.dump(state, f)
PY

pushd "${WORKDIR}" >/dev/null
terraform init -backend=false -input=false >/dev/null

DESTROY_LOG="${WORKDIR}/destroy-plan.log"
echo "=== Guarantee 1: destroy must be rejected ==="
if terraform plan -destroy -refresh=false -input=false >"${DESTROY_LOG}" 2>&1; then
  echo "FAIL: terraform plan -destroy succeeded; prevent_destroy did not fire" >&2
  cat "${DESTROY_LOG}"
  exit 1
fi
if ! grep -q "Instance cannot be destroyed" "${DESTROY_LOG}"; then
  echo "FAIL: destroy plan failed for an unexpected reason" >&2
  cat "${DESTROY_LOG}"
  exit 1
fi
echo "PASS: destroy correctly rejected by prevent_destroy"

echo "=== Guarantee 2: topology drift is ignored ==="
terraform plan -refresh=false -input=false -out="${WORKDIR}/update.tfplan" >/dev/null
terraform show -json "${WORKDIR}/update.tfplan" >"${WORKDIR}/update-plan.json"
python3 - "${WORKDIR}/update-plan.json" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
changes = [
    c for c in plan.get("resource_changes", [])
    if c.get("address") == 'module.net.harvester_network.this["verify-lifecycle-guard"]'
]
if len(changes) != 1:
    raise SystemExit(f"FAIL: expected one network resource change, got {len(changes)}")
change = changes[0]["change"]
if change["actions"] != ["update"]:
    raise SystemExit(f"FAIL: expected positive-control update, got {change['actions']}")
before, after = change["before"], change["after"]
if after.get("description") != "mutable-positive-control":
    raise SystemExit("FAIL: mutable description positive control did not appear")
if before.get("vlan_id") != 100 or after.get("vlan_id") != 100:
    raise SystemExit("FAIL: vlan_id was not frozen at state value 100")
if before.get("cluster_network_name") != "legacy-network" or after.get("cluster_network_name") != "legacy-network":
    raise SystemExit("FAIL: cluster_network_name was not frozen at state value legacy-network")
print("PASS: mutable description diff proves comparison occurred; VLAN and ClusterNetwork remained frozen")
PY

popd >/dev/null
echo "All lifecycle guarantees verified."
