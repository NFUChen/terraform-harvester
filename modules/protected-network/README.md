# protected-network

## Purpose and scope

Creates namespaced Harvester NetworkAttachmentDefinitions (NADs) with a
create-once lifecycle. Optionally composes the sibling `vlan-dhcp` and
`vlan-nat-gateway` utility modules per network. It does not create namespaces,
ClusterNetworks, VLANConfigs, physical uplinks, or switch configuration.

## Requirements and providers

| Dependency | Declared constraint / requirement |
| --- | --- |
| Terraform | `>= 1.3` in `versions.tf`; this is not a compatibility guarantee for the complete module tree. The DHCP child uses cross-variable validation requiring Terraform 1.9+. Use Terraform 1.9+ for composition and tests. |
| `harvester/harvester` | `= 1.9.0` |
| `hashicorp/kubernetes` | `~> 2.38` (>= 2.38.0, < 3.0.0), also required by the child modules |

Configure providers in the caller. The target namespace and ClusterNetwork
must exist. Ensure ClusterNetwork readiness, VLANConfig coverage, uplinks,
trunks, and MTU on every eligible node. The data-source lookup checks existence,
not end-to-end readiness. Provider 1.9.0 has a separate one-minute
ClusterNetwork readiness wait that module timeouts do not extend.

Optional services additionally require Multus, a compatible VLAN NAD, working
Pod-network egress for NAT, and admission policies permitting their security
contexts. See the sibling module READMEs for workload requirements.

## Default context

The default namespace is `harvester-public`; the ClusterNetwork and each VLAN ID
are required choices. With `services` omitted, this creates only NADs using
`route.mode = "auto"`, not DHCP or a gateway. This suits an existing VLAN whose
addressing/routing is provided elsewhere and whose route metadata can be derived
by Harvester. Choose manual CIDR/gateway metadata before creation when needed;
existing NAD configuration is frozen, so later topology changes require migration.

Supplying `services` enables both DHCP and NAT unless explicitly disabled. Defaults
reserve host offsets 1/2 for gateway/DHCP, lease offsets 100–200 for `12h`, and
advertise `1.1.1.1` and `8.8.8.8` as DNS. These fit a lab `/24` with those addresses
available and public DNS reachable; smaller subnets need pool overrides, and private
DNS needs explicit resolvers. Both services are single-instance, non-HA workloads;
use other infrastructure when persistent leases or uninterrupted egress are needed.

## Usage

Caller configuration snippet, **not a standalone root module**: declare and
supply the referenced variables and configure providers separately. The source
path below assumes the caller is at the **repository root**; adjust it for a
caller located elsewhere.

```hcl
module "networks" {
  source = "./modules/protected-network"

  cluster_network_name = var.cluster_network_name

  networks = {
    "lab-vlan" = { vlan_id = 120 }
  }
}
```

`lab-vlan` and VLAN `120` are illustrative choices, not defaults; select a VLAN
carried by your ClusterNetwork's uplinks. This NAD-only example keeps the default
namespace and auto-route metadata. Consumers use `module.networks.ids["lab-vlan"]`
as the namespace-qualified network ID.

For a lab VLAN needing both services, replace the `lab-vlan` value above with:

```hcl
"lab-vlan" = {
  vlan_id = 120
  services = {
    cidr          = "192.168.120.0/24"
    node_selector = var.vlan_node_selector
  }
}
```

The CIDR is an example choice: verify it does not overlap your networks and reserve
`.1`/`.2`. This uses the service defaults above, including pool `.100`–`.200`;
provide a selector for actual VLAN-capable nodes. Services do not set NAD route
metadata. Do not deploy another DHCP server or gateway on the same addresses.

## Inputs

| Name | Type | Required / default | Meaning |
| --- | --- | --- | --- |
| `namespace` | `string` | `"harvester-public"` | Existing namespace; DNS-1123 label. |
| `cluster_network_name` | `string` | Required | Existing ClusterNetwork; DNS-1123 label, shared by all networks. |
| `networks` | `map(object)` | Required, non-empty | Exact NAD names mapped to the attributes below. |
| `labels` | `map(string)` | `{}` | Common labels; override per-network labels but not module-managed labels. |
| `tags` | `map(string)` | `{}` | Common tags; per-network tags take precedence. |
| `timeouts` | `object` | `{}` | Optional `create = "5m"`, `read = "2m"`, `update = "5m"`, `delete = "10m"`. |

Each `networks` value supports:

| Attribute | Type | Required / default | Meaning |
| --- | --- | --- | --- |
| `vlan_id` | `number` | Required | Integer from 0 through 4094. |
| `description` | `string` | `null` | Initial NAD description. |
| `labels` | `map(string)` | `{}` | Initial per-network labels. |
| `tags` | `map(string)` | `{}` | Initial per-network tags. |
| `route` | `object` | `{}` | Optional route metadata, detailed below. |
| `route.mode` | `string` | `"auto"` | `auto` rejects CIDR/gateway; `manual` requires both. |
| `route.cidr` | `string` | `null` | IPv4 CIDR for manual routing. |
| `route.gateway` | `string` | `null` | IPv4 gateway within the manual CIDR. Membership validation does not prove it is a usable host. |
| `route.dhcp_server_ip` | `string` | `null` | IPv4 address for auto-route metadata only; does not create DHCP. |
| `services` | `object` | `null` | Optional workloads; at least one service must be enabled when supplied. |
| `services.cidr` | `string` | Required with `services` | IPv4 service subnet; caller must keep it consistent with route metadata. |
| `services.node_selector` | `map(string)` | Required with `services`, non-empty | Select only nodes whose uplinks carry the VLAN. |
| `services.enable_dhcp` | `bool` | `true` | Create a DHCP child workload. |
| `services.enable_nat` | `bool` | `true` | Create a NAT child workload. |
| `services.pool_start_offset` | `number` | `100` | First DHCP host offset; must fit the subnet and follow reserved offsets. |
| `services.pool_end_offset` | `number` | `200` | Last DHCP host offset; must fit the subnet, exclude broadcast, and be >= start. |
| `services.dns_servers` | `list(string)` | `["1.1.1.1", "8.8.8.8"]` | DNS advertised by DHCP; unlike standalone DHCP, defaults to explicit resolvers. |
| `services.lease_time` | `string` | `"12h"` | DHCP lease duration. |
| `services.dhcp_image` | `string` | `null` | Override DHCP image; null uses the pinned dnsmasq digest documented in `../vlan-dhcp/README.md`. |
| `services.nat_image` | `string` | `null` | Override NAT image; null uses the pinned netshoot digest documented in `../vlan-nat-gateway/README.md`. |

NAD keys must be DNS-1123 subdomains up to 253 characters. With services, they
must instead be single DNS-1123 labels up to 58 characters. Global and
per-network labels cannot set `network.harvesterhci.io/clusternetwork`.
The module owns `app.kubernetes.io/managed-by`, `app.kubernetes.io/instance`,
and `platform.harvester.io/protected`.

## Outputs

Maps below are keyed by NAD name unless stated otherwise.

| Output | Meaning |
| --- | --- |
| `ids` | NAD IDs in `namespace/name` form. |
| `names` | NAD names. |
| `declared_vlan_ids` | VLAN IDs from current caller configuration. |
| `observed_vlan_ids` | VLAN IDs last observed in provider state. |
| `declared_cluster_network_name` | Scalar ClusterNetwork name from current input. |
| `observed_cluster_network_names` | ClusterNetwork names last observed in provider state. |
| `declared_routes` | Configured objects with `mode`, `cidr`, `gateway`, `dhcp_server_ip`. |
| `observed_routes` | Corresponding route objects from provider state. |
| `route_connectivity` | Provider/controller observation, not proof of guest or application connectivity. |
| `dhcp_server_ips` | Server addresses for DHCP-enabled networks only. |
| `gateway_ips` | Gateway addresses for NAT-enabled networks only. |

## Behavior and limitations / lifecycle

- NAD resources use **`prevent_destroy = true` and `ignore_changes = all`**.
  Ordinary applies do not reconcile existing NAD fields, including VLAN,
  ClusterNetwork, routes, labels, tags, and description. This avoids provider
  1.9.0 feeding controller-derived auto-route values into invalid updates.
  Imported NADs are also subject to this all-fields ignore behavior.
- Protection is not absolute: lifecycle rules live in configuration, not state.
  Removing the module/resource configuration removes the protection; direct
  API operations are also outside Terraform's guard. Use CI/RBAC and approval
  controls for deletion, replacement, and configuration removal.
- Declared and observed outputs can differ. They expose selected drift, not a
  full drift audit, and ordinary apply will not repair it. Use a new NAD name
  for intended changes rather than same-name replacement. A running Pod can
  retain its old attachment while a restarted Pod reads changed NAD topology.
- The module does not discover consumers. Before decommissioning, inspect VM,
  VMI, and Pod references, migrate consumers to the new NAD, verify attachment
  and traffic after restart/migration, and obtain approval. Relinquishing state
  ownership does not delete a NAD; remove matching configuration in a controlled
  sequence to avoid recreation. Delete the retired NAD only after consumer
  checks. NAD deletion does not delete VMs but can prevent their Pods reattaching.
- Services reserve `cidrhost(cidr, 1)` for the gateway and
  `cidrhost(cidr, 2)` for DHCP. These offsets are not configurable here; use the
  child modules directly when their wider interfaces are needed. DHCP-only
  composition still advertises offset 1, which must be provided separately.
- Services do not implicitly set NAD route metadata. Declare needed metadata
  before creation without making the NAD depend on a child workload output.
- Child workloads remain independently updatable and deletable; NAD lifecycle
  protection does not protect them. Both are single-Pod, `Recreate`, lab/sandbox
  designs: DHCP leases are ephemeral, NAT sessions are lost on Pod replacement,
  and neither provides HA. NAT does not provide DNS.

## Testing

Run from `modules/protected-network` with Terraform 1.9+:

```sh
terraform init -backend=false
terraform validate
terraform test
```

The suite uses mocked providers and plan-only runs to check validation, network
attributes, outputs, and service composition. It does not prove live network
connectivity or destruction protection against existing state. Provider
installation still requires registry access or a configured local mirror/cache.

An optional lifecycle check uses synthetic state and a live, read-only
ClusterNetwork lookup (no infrastructure apply/delete). From the module
directory, supply your own values:

```sh
scripts/verify_lifecycle_guarantees.sh "$CLUSTER_NETWORK_NAME" "$KUBECONFIG_PATH"
```

This separate script requires Bash, Python 3, Terraform, and cluster access.
Live canary checks remain necessary for node coverage, DHCP, routes, DNS, MTU,
and application connectivity.
