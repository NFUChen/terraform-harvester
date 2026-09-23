#!/usr/bin/env bash
# Reproducible, read-only proof of protected-network's lifecycle guarantees:
#   1. prevent_destroy rejects `terraform plan -destroy` against an existing
#      network.
#   2. ignore_changes=all suppresses controller-managed labels/auto-route
#      state and every caller-side edit, avoiding provider 1.9.0's
#      Optional+Computed route state feedback bug.
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
      # Deliberately differs from fabricated state. ignore_changes=all must
      # keep the live/create-time values and produce a no-op plan.
      vlan_id     = 200
      description = "caller-side-edit-that-must-be-ignored"
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
                # Simulate values auto-discovered and written by the Harvester
                # controller, then imported into Optional+Computed state.
                "route_cidr": "192.0.2.0/24",
                "route_gateway": "192.0.2.1",
                "route_dhcp_server_ip": "",
                "route_connectivity": "reachable",
                "config": "{\"vlan\":100}",
                "description": "create-time-description",
                "labels": {
                    "network.harvesterhci.io/clusternetwork": "legacy-network",
                    "network.harvesterhci.io/ready": "true",
                    "network.harvesterhci.io/type": "L2VlanNetwork",
                    "network.harvesterhci.io/vlan-id": "100",
                },
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

echo "=== Guarantee 2: controller drift and all caller edits are ignored ==="
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
if change["actions"] != ["no-op"]:
    raise SystemExit(f"FAIL: expected a no-op plan for the create-once NAD, got {change['actions']}")
before, after = change["before"], change["after"]
expected = {
    "vlan_id": 100,
    "cluster_network_name": "legacy-network",
    "description": "create-time-description",
    "route_mode": "auto",
    "route_cidr": "192.0.2.0/24",
    "route_gateway": "192.0.2.1",
}
for key, value in expected.items():
    if before.get(key) != value or after.get(key) != value:
        raise SystemExit(f"FAIL: {key} did not remain frozen at state value {value!r}")
if after.get("labels", {}).get("network.harvesterhci.io/ready") != "true":
    raise SystemExit("FAIL: controller-managed labels were not retained as no-op state")
print("PASS: caller edits and controller-managed label/auto-route state produce a no-op plan")
PY

popd >/dev/null
echo "All lifecycle guarantees verified."
