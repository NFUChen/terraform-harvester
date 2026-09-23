# protected-network

Wrapper around `harvester_network` for Harvester provider `1.9.0`. It creates
namespaced Multus NetworkAttachmentDefinitions (NADs) and prevents ordinary
Terraform operations from silently changing VLAN identity or deleting a
network.

Two limits to understand before relying on it:

- The module never discovers consumers. It does not know which VMs use a NAD;
  consumer checks are manual and documented below.
- Terraform lifecycle rules live in configuration. Deleting the module block
  removes them, so CI/RBAC must also gate network deletion.

## Safety guarantees

While the module remains configured:

- every network has `prevent_destroy = true`;
- `vlan_id` changes are ignored;
- `cluster_network_name` changes are ignored;
- route combinations are validated before the provider runs;
- neither global nor per-network labels may set the controller-owned
  `network.harvesterhci.io/clusternetwork` key;
- the ClusterNetwork is looked up at plan time, so a missing ClusterNetwork
  fails before apply. This proves existence, not Ready state; the provider
  performs its own separate readiness wait during create/update.

The first two controls are verified by a committed, reproducible script that
builds throwaway state and only runs `terraform plan`:

```sh
scripts/verify_lifecycle_guarantees.sh <cluster_network_name> <kubeconfig>
```

It performs one live, read-only ClusterNetwork lookup (no apply/delete), then
asserts that `terraform plan -destroy` fails with
`Instance cannot be destroyed`. Its update plan includes a mutable description
as a positive control while configuration VLAN 200 differs from state VLAN 100
and the configured ClusterNetwork differs from state `legacy-network`; plan
JSON must retain both frozen state values.

Terraform lifecycle exists in configuration, not state. Removing the entire
module block also removes its lifecycle controls. Production CI/RBAC must
therefore block NAD deletion and network module removal without explicit
approval.

## Quick start — automatic route mode

```hcl
module "workload_networks" {
  source = "./modules/protected-network"

  namespace            = "harvester-public"
  cluster_network_name = "workload"

  networks = {
    "production-v100" = {
      vlan_id = 100
    }

    "database-v110" = {
      vlan_id = 110
      route = {
        mode           = "auto"
        dhcp_server_ip = "172.16.110.10"
      }
    }
  }
}
```

## Manual route mode

```hcl
networks = {
  "production-v200" = {
    vlan_id = 200
    route = {
      mode    = "manual"
      cidr    = "172.16.200.0/24"
      gateway = "172.16.200.1"
    }
  }
}
```

Validation rules:

- `auto` rejects CIDR/gateway;
- `manual` requires CIDR and gateway;
- manual gateway must share the CIDR prefix. This checks membership only; it
  does not reject subnet/broadcast endpoints because `/31` and `/32` have
  different valid-host semantics. Platform review must confirm the gateway is
  usable for the chosen subnet;
- DHCP server IP is allowed only with `auto`;
- VLAN ID must be an integer from 0 through 4094;
- all addresses are validated as IPv4 because Harvester's provider examples
  and route fields are IPv4-oriented.

## Attach to virtual-machine

```hcl
module "web" {
  source = "./modules/virtual-machine"

  name_prefix = "web"
  root_image  = data.harvester_image.ubuntu_noble.id

  network_interfaces = [{
    name           = "nic-1"
    type           = "bridge"
    model          = "virtio"
    network_name   = module.workload_networks.ids["production-v100"]
    wait_for_lease = true
  }]
}
```

The output ID is `namespace/name`, which is exactly what the VM provider
expects in `network_interface.network_name`.

For non-management networks, `wait_for_lease = true` generally requires
qemu-guest-agent in the guest. Without it the VM may be running while
Terraform waits until timeout for an IP.

## Why VLAN ID is frozen

A network is a Multus NAD. The VM references its name, not its VLAN ID. Multus
reads NAD config when creating the virt-launcher Pod.

If VLAN ID is changed in place:

- already-running Pods can remain attached to the old VLAN;
- restarted, migrated, or recreated Pods read the new VLAN;
- VMs using the same NAD name can split across different VLANs;
- the fault may appear days later during node drain or VM restart;
- route CIDR/gateway metadata can become inconsistent with the new VLAN.

The module therefore ignores VLAN/ClusterNetwork config changes. Terraform
remains documentation for the originally declared topology, but cannot mutate
it through ordinary apply.

## VLAN or ClusterNetwork migration

Topology changes use a new NAD name, not an in-place update or same-name
replacement.

1. Add a new network, for example `production-v200`, while retaining
   `production-v100`.
2. Verify ClusterNetwork Ready and VLANConfig coverage on every target node.
3. Verify physical switch trunk, MTU, DHCP, gateway, and routes.
4. Attach a disposable canary VM to the new NAD and test traffic.
5. Migrate workload VMs in small batches by changing `network_name` and
   restarting/recreating the VMI.
6. Verify each batch before continuing.
7. Confirm no VM, VMI, or Pod references the old NAD.
8. Remove the old NAD from Terraform state without deleting it.
9. Remove the old key from config.
10. Delete the old NAD through an approved operational process.

Do not use `terraform apply -replace` on a production network. Replacing a NAD
does not delete VM objects, but creates a window where restarted Pods cannot
find the NAD and can leave running/restarted VMs on different topology.

## Decommissioning a network

### Consumer check

```sh
kubectl get vm -A -o yaml
kubectl get vmi -A -o yaml
kubectl get pod -A -o yaml
kubectl get network-attachment-definitions -A
```

Search desired VM/VMI networks and Pod Multus annotations for the exact
`namespace/name` NAD reference. Check both desired specs and running Pods.

### Relinquish Terraform ownership without deletion

A `removed` block cannot address one `for_each` resource instance. Use an
approved state operation:

```sh
terraform state rm \
  'module.workload_networks.harvester_network.this["production-v100"]'
```

Then remove the matching map key from configuration. Verify the NAD still
exists before any further apply:

```sh
kubectl -n harvester-public get network-attachment-definition production-v100
```

### Delete outside Terraform

Only after consumer checks and migration approval, delete the old NAD via the
platform operational runbook. Deleting the NAD does not delete VM resources,
but a VM Pod recreated afterward cannot attach that network.

## ClusterNetwork and VLANConfig prerequisites

This module does not create or modify:

- `harvester_clusternetwork`;
- `harvester_vlanconfig`;
- node uplink NIC/bond settings;
- physical switch trunk configuration.

Those belong in a more restricted foundation module/state. The network
provider waits at most one minute for ClusterNetwork Ready, regardless of this
module's create/update timeout. A Ready ClusterNetwork does not prove every
node uplink or physical VLAN path works.

Before creating workload networks, verify VLANConfig matched nodes and uplink
health on every node that may host the VM.

## Route updates

The module freezes VLAN and ClusterNetwork, but allows route annotation
updates. A route update does not restart VM Pods and does not prove guest
connectivity. Review route changes as production network changes and validate
DHCP/gateway/application traffic after apply.

## Labels

The module reserves and controls:

```text
app.kubernetes.io/managed-by
app.kubernetes.io/instance
platform.harvester.io/protected
```

Callers cannot set the controller-owned:

```text
network.harvesterhci.io/clusternetwork
```

Harvester/controller-managed labels can still appear in state because provider
1.9.0 marks labels Optional+Computed.

## Import

Declare the exact name/VLAN/ClusterNetwork/routes first, then import:

```sh
terraform import \
  'module.workload_networks.harvester_network.this["production-v100"]' \
  harvester-public/production-v100
```

Inspect the first plan carefully. Do not accept any unexpected topology change.
Because VLAN and ClusterNetwork are ignored after import, the live NAD remains
unchanged while labels/routes can reconcile.

## Outputs

| Output | Meaning |
| --- | --- |
| `ids` | NAD IDs (`namespace/name`) for VM `network_name` |
| `names` | NAD names |
| `declared_vlan_ids` | Current config values; can differ from live values because topology is frozen |
| `observed_vlan_ids` | VLAN IDs last observed from live NAD/provider state |
| `declared_cluster_network_name` | Current module input; ordinary apply does not mutate live topology |
| `observed_cluster_network_names` | ClusterNetwork label last observed on each live NAD |
| `declared_routes` | Current route config |
| `observed_routes` | Route values last observed from the live NAD |
| `route_connectivity` | Controller/provider observation, not end-to-end proof |

## CI/RBAC recommendations

Production pipelines should block:

- `harvester_network` delete or replacement;
- removal of a network module/key without an approved migration ticket;
- any direct NAD update to VLAN CNI config;
- ClusterNetwork/VLANConfig changes without network-team approval.

Separate foundation credentials (ClusterNetwork/VLANConfig/uplinks) from
workload-network credentials. Enable audit alerting for NAD delete and VLAN
config mutations.

## Verification

```sh
terraform fmt -recursive -check
terraform validate
terraform test
```
