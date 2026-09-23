---
name: harvester-network
description: Harvester Terraform VM network management using harvester_network, NetworkAttachmentDefinition (NAD), Multus, VLAN IDs, ClusterNetwork, VLANConfig, route modes, DHCP server IP, gateway/CIDR, import, deletion protection, and network migration. Use whenever a user asks to create, inspect, modify, migrate, protect, import, or troubleshoot Harvester VLAN networks or VM network_interface.network_name, even if they only mention VLAN, NAD, Multus, bridge NIC, route connectivity, ClusterNetwork readiness, or VM connectivity after restart.
compatibility: Requires Terraform with harvester/harvester provider 1.9.0 and Harvester kubeconfig access.
metadata:
  domain: harvester
  resource: harvester_network
---

# Harvester Network

Use this skill to manage Harvester VM networks without silently breaking running workloads. A `harvester_network` is a namespaced Kubernetes `NetworkAttachmentDefinition` (NAD) consumed by Multus when a VM's virt-launcher Pod is created.

## First determine intent

Collect only missing information:

1. Operation: create, inspect, import, update route metadata, migrate VLAN, decommission, or troubleshoot.
2. Identity: network name and namespace.
3. ClusterNetwork: existing cluster network name and whether its VLANConfig/uplink is ready on all target nodes.
4. VLAN identity: VLAN ID `0..4094` and switch trunk availability.
5. Routing: `auto` with optional DHCP server IP, or `manual` with required CIDR and gateway.
6. Consumers: VM/VMI/Pod references to the NAD.
7. Protection: whether this is a production network that must reject ordinary destroy/replacement.

Do not invent VLAN IDs, gateways, CIDRs, DHCP addresses, ClusterNetwork names, node uplinks, or switch configuration.

## Resource mental model

Terraform:

```hcl
resource "harvester_network" "production" {
  name                 = "production-v100"
  namespace            = "harvester-public"
  vlan_id              = 100
  cluster_network_name = "workload"
  route_mode           = "auto"
}
```

Underlying object:

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: production-v100
  namespace: harvester-public
  labels:
    network.harvesterhci.io/clusternetwork: workload
spec:
  config: '{..."vlan":100...}'
```

VM attachment:

```hcl
network_interface {
  name         = "nic-1"
  type         = "bridge"
  network_name = harvester_network.production.id
}
```

The VM stores the NAD reference (`namespace/name`), not the VLAN ID.

## Safe production pattern

```hcl
resource "harvester_network" "production" {
  name                 = "production-v100"
  namespace            = "harvester-public"
  vlan_id              = 100
  cluster_network_name = data.harvester_clusternetwork.workload.name

  route_mode           = "auto"
  route_dhcp_server_ip = ""

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      vlan_id,
      cluster_network_name,
    ]
  }
}
```

Why freeze topology:

- `vlan_id` is embedded into NAD `spec.config` and provider schema does not mark it ForceNew.
- Existing running VM network attachments are configured when their Pods start; an in-place NAD change may not affect them immediately.
- Restarted/migrated VMs then read the new VLAN while old VM Pods remain on the old VLAN, creating a split network.
- Changing ClusterNetwork changes the physical/uplink topology and is also a migration, not a routine update.

## Route modes

### Auto

```hcl
route_mode           = "auto"
route_dhcp_server_ip = "192.0.2.10" # optional; empty is valid
```

With `auto`:

- `route_cidr` must be omitted/empty;
- `route_gateway` must be omitted/empty;
- `route_dhcp_server_ip` may be supplied.

### Manual

```hcl
route_mode    = "manual"
route_cidr    = "172.16.100.0/24"
route_gateway = "172.16.100.1"
```

With `manual`:

- CIDR and gateway are both required;
- `route_dhcp_server_ip` must be omitted/empty;
- gateway should belong to the CIDR;
- CIDR/gateway values must match the intended VLAN network.

The provider performs these cross-field checks in the constructor, so basic `terraform validate` does not catch all invalid combinations. A wrapper module should validate them before provider execution.

## Create behavior

Before creating or updating the NAD, provider `Validate()` waits up to one minute for the referenced `ClusterNetwork` Ready condition. If it is absent or unready, the operation fails.

This does not verify:

- VLANConfig covers every node that may run the VM;
- uplink NIC/bond health;
- physical switch trunk permits the VLAN;
- DHCP/gateway is reachable;
- VM guest receives an address.

Validate those separately before workload rollout.

## Delete and replace behavior

Provider delete directly deletes the NAD and waits for the object to disappear. It does not inspect VM consumers or restart/delete VMs.

Replacing/deleting a network does **not** delete VM resources, but it creates risks:

- a running VM usually retains its existing attachment until its Pod is recreated;
- a VM restarting while the NAD is absent may fail Pod sandbox/network setup;
- recreating the same NAD name with a new VLAN sends restarted VMs to the new VLAN while old Pods remain on the old VLAN;
- the cluster can enter a hard-to-debug split state.

Production wrappers should use `prevent_destroy` and frozen topology.

## VLAN migration

Never replace or update a production NAD in place to change VLAN identity. Use blue/green migration:

1. Create a new network with a new stable name, such as `production-v200`.
2. Confirm ClusterNetwork and VLANConfig/uplinks are Ready on target nodes.
3. Confirm switch trunk, DHCP, gateway, and routes for VLAN 200.
4. Attach a disposable canary VM and validate traffic.
5. Migrate workload VMs in batches by changing `network_name` and restarting/recreating the VMI.
6. Validate each batch.
7. Confirm no VM/VMI/Pod references the old NAD.
8. Remove Terraform ownership without deleting the NAD.
9. Delete the old NAD only through an approved decommission workflow.

## Consumer checks

Provider has no reliable “attached VM” field for networks. Inspect actual references:

```sh
kubectl get vm -A -o yaml
kubectl get vmi -A -o yaml
kubectl get pod -A -o yaml
kubectl get network-attachment-definitions -A
```

Search VM/VMI networks and Pod Multus annotations for `namespace/name` references. Check both desired VM specs and currently running Pods because they can temporarily point at different effective topology during migration.

## Labels caveat

Provider marks `labels` Optional+Computed because the API server/controller updates them. It also sets the ClusterNetwork label internally. Do not allow callers to override controller-owned keys such as:

```text
network.harvesterhci.io/clusternetwork
```

Wrapper modules should merge platform-managed labels last.

## Import

```sh
terraform import harvester_network.production harvester-public/production-v100
```

After import, reconcile:

- VLAN ID;
- ClusterNetwork label;
- route mode/annotation;
- CIDR/gateway/DHCP server IP;
- labels/tags;
- raw `config` drift.

Do not apply any unexpected VLAN or ClusterNetwork change. Freeze topology before managing an existing production NAD.

## Troubleshooting order

1. Inspect NAD `spec.config`, labels, and route annotation.
2. Inspect ClusterNetwork Ready condition.
3. Inspect VLANConfig matched nodes, uplink NICs/bond, and MTU.
4. Verify physical switch trunk and VLAN membership.
5. Inspect VM and VMI network references.
6. Inspect virt-launcher Pod Multus annotations/events.
7. For named/non-management networks, verify qemu-guest-agent when Terraform waits for lease/IP.
8. Verify DHCP/gateway/CIDR consistency and route connectivity status.
9. Compare restarted vs non-restarted VM Pods for split-topology symptoms.

## Safety rules

- Freeze VLAN ID and ClusterNetwork after creation.
- Protect production NADs from ordinary Terraform destroy/replacement.
- Treat VLAN/ClusterNetwork changes as migration to a new named network.
- Never delete a NAD until all VM/VMI/Pod consumers are gone.
- Keep ClusterNetwork/VLANConfig in a foundation layer separate from namespaced workload networks.
- Do not assume successful NAD creation proves physical connectivity.
- Review saved plans and block network delete/replace in CI.

Read `references/api.md` for provider 1.9.0 implementation details and wrapper-module design guidance.
