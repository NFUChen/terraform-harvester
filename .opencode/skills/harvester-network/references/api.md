# harvester_network provider 1.9.0 API reference

## Resource model

`harvester_network` wraps a namespaced Multus `NetworkAttachmentDefinition`:

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: workload-v100
  namespace: harvester-public
spec:
  config: <generated VLAN CNI JSON>
```

## Terraform mapping

| Field | Underlying representation | Provider behavior |
|---|---|---|
| `name` | `metadata.name` | Required identity |
| `namespace` | `metadata.namespace` | Optional, common default `default` |
| `vlan_id` | generated `spec.config` JSON | Required integer 0..4094; not ForceNew |
| `cluster_network_name` | controller-owned label + generated config | Required; provider waits for ClusterNetwork Ready |
| `route_mode` | route annotation | Default `auto`; `auto` or `manual` |
| `route_dhcp_server_ip` | route annotation server IP | Conflicts with CIDR/gateway |
| `route_cidr` | route annotation CIDR | Optional+Computed; required for manual |
| `route_gateway` | route annotation gateway | Optional+Computed; required for manual |
| `config` | `spec.config` | Optional+Computed; generated from name/ClusterNetwork/VLAN |
| `route_connectivity` | parsed route annotation status | Computed |
| `labels` | `metadata.labels` | Optional+Computed because API/controller updates them |
| `tags` | labels | Harvester tag encoding |

## Constructor order and validation

Processors effectively run in schema setup order:

1. Set ClusterNetwork name and label.
2. Generate VLAN config from network name, ClusterNetwork, and VLAN ID.
3. Set DHCP server IP.
4. Set route CIDR.
5. Set gateway.
6. Set route mode and serialize/validate Layer3NetworkConf.

Rules enforced at construction:

- Manual mode requires CIDR and gateway.
- Auto mode rejects CIDR and gateway.
- Schema `ConflictsWith` rejects DHCP server IP together with CIDR/gateway.
- Layer3NetworkConf parser performs additional route syntax validation.

The schema itself validates only VLAN range, nonempty ClusterNetwork name, and route mode enum. Cross-field errors may appear only when the provider constructs the resource.

## ClusterNetwork readiness

`Validate()` polls the cluster-scoped `ClusterNetwork` for condition `Ready=True`:

- hardcoded timeout: 1 minute;
- delay: 1 second;
- minimum poll interval: 3 seconds.

This is separate from the resource's configured create/update timeout. Increasing network create timeout does not increase this one-minute ClusterNetwork readiness limit.

The check proves only ClusterNetwork controller readiness, not physical VLAN connectivity or per-node VLANConfig coverage.

## Create/read/update/delete

### Create

1. Build NAD metadata/config/route annotation.
2. Wait for ClusterNetwork Ready.
3. Create NAD through Harvester's generated K8s CNI client.
4. Import returned object immediately.

There is no connectivity readiness waiter after NAD creation.

### Read

Direct GET by namespace/name. NotFound clears state. Importer parses VLAN from `spec.config`, route annotation, ClusterNetwork label, and controller-managed labels.

### Update

GET existing NAD, run constructor and ClusterNetwork readiness check, then normal Update. No fields are ForceNew; Terraform may plan in-place VLAN or ClusterNetwork changes.

### Delete

Directly delete NAD and poll until NotFound. No VM/VMI/Pod reference check is performed. Default delete timeout is five minutes.

## Running VM behavior during NAD changes

Multus consumes NAD config when the virt-launcher Pod is created. Updating NAD does not necessarily reconfigure already-running Pods.

Consequences of in-place VLAN change:

- existing Pods can remain on old VLAN;
- restarted/migrated/recreated Pods use new VLAN;
- workloads using the same NAD name can split across two VLANs;
- route annotation may no longer match VLAN addressing;
- failure can be delayed until a future restart/node drain.

Consequences of delete/recreate:

- VM objects are not deleted;
- existing attachments may keep working temporarily;
- new Pods may fail while NAD is absent;
- recreated same-name NAD restores reference resolution but may use different topology.

## Importer behavior

Importer derives:

- VLAN ID only when network type label identifies a VLAN network;
- raw config from NAD spec;
- route fields from the Harvester network-controller route annotation;
- ClusterNetwork name from controller label.

Malformed NAD config or route annotation causes refresh/import errors.

## Recommended wrapper contract

A production-safe wrapper should:

- accept a map keyed by exact NAD name;
- require namespace and ClusterNetwork explicitly;
- validate VLAN 0..4094;
- validate network names as DNS-1123 subdomains;
- expose route as a typed object rather than independent conflicting strings;
- validate auto/manual route combinations and IP/CIDR relationships;
- freeze VLAN ID and ClusterNetwork with `ignore_changes`;
- protect NAD with `prevent_destroy`;
- check ClusterNetwork existence at plan time;
- reserve controller-owned label keys;
- output NAD IDs for VM `network_interface.network_name`.

`ignore_changes` should apply to topology, not route metadata. Route updates still require rollout awareness because provider does not restart VM Pods.

## Suggested API

```hcl
module "networks" {
  source = "./modules/protected-network"

  namespace            = "harvester-public"
  cluster_network_name = "workload"

  networks = {
    "production-v100" = {
      vlan_id = 100
      route = {
        mode           = "manual"
        cidr           = "172.16.100.0/24"
        gateway        = "172.16.100.1"
        dhcp_server_ip = null
      }
    }
  }
}
```

Outputs:

- IDs (`namespace/name`) keyed by NAD name;
- names;
- VLAN IDs declared at creation;
- ClusterNetwork names;
- route configuration;
- observed route connectivity.

Do not claim output connectivity means VM-to-gateway/application connectivity is proven.

## Investigated sources

- Registry docs for `harvester_network` resource/data source, provider 1.9.0.
- Installed provider schema via `terraform providers schema -json`.
- `internal/provider/network/schema_network.go`
- `internal/provider/network/resource_network.go`
- `internal/provider/network/resource_network_constructor.go`
- `internal/provider/network/resource_network_validator.go`
- `pkg/importer/resource_network_importer.go`
- `pkg/constants/constants_network.go`
