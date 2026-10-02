# vlan-dhcp

## Purpose and scope

Runs one dnsmasq Deployment serving DHCP on a single existing Harvester VLAN
NetworkAttachmentDefinition (NAD) via Multus. One module call serves one VLAN
and derives all addresses from a caller-supplied IPv4 CIDR.

The module does not create NADs, namespaces, Services, or routing, and it does
not create or verify the advertised gateway or DNS resolvers. It is a
lab/sandbox utility: a single Pod with an ephemeral lease database, not an HA
DHCP design.

## Requirements and providers

| Dependency | Declared constraint / requirement |
| --- | --- |
| Terraform | `>= 1.3` in `versions.tf`; this is not a verified compatibility guarantee. Variable validation references other variables, which requires Terraform 1.9+, so use Terraform 1.9+. |
| `hashicorp/kubernetes` | `~> 2.38` (>= 2.38.0, < 3.0.0), configured by the caller |

Cluster requirements: the target NAD must already exist in the namespace parsed
from `network_id`; Multus must attach it as `net1` with no IPAM; the selected
nodes must carry the VLAN uplink and trunk. The container runs as UID 0 with
`NET_ADMIN`, `NET_RAW`, `NET_BIND_SERVICE`, `SETUID`, and `SETGID`, so cluster
admission policy must permit that security context. The image must provide
`/bin/sh`, `dnsmasq`, `ip`, `grep`, and `netstat`. Deploy only in a
platform-controlled namespace.

## Default context

Defaults advertise host offset 1 as the router, bind offset 2 as the server, and
issue `12h` leases with no DNS domain. The NAD, CIDR, pool offsets, and node
selector are all required: the module cannot infer a safe address range. Workload
names and the namespace derive from `network_id`, so DHCP runs beside its NAD.

By default `dns_servers` is null, which advertises the gateway as the resolver and
assumes that gateway forwards DNS. Set explicit resolvers when it does not. The
gateway address is advertised only; provide it separately, for example with
`../vlan-nat-gateway` using the same CIDR and offset 1. This is a single Pod with
leases in an `emptyDir`, suitable for lab/sandbox VLANs where a brief DHCP outage
and reassigned addresses are acceptable. Use durable HA DHCP when they are not.

## Usage

Caller configuration snippet, **not a standalone root module**: declare and
supply the referenced variables and configure the Kubernetes provider
separately. The source path below assumes the caller is at the **repository
root**; adjust it for a caller located elsewhere.

The CIDR and pool offsets below are illustrative: this leases `192.168.120.100`
through `192.168.120.200`, leaving `.1` for the gateway and `.2` for this server.
Verify the subnet matches the VLAN and that no other DHCP server serves it.

```hcl
module "vlan_dhcp" {
  source = "./modules/vlan-dhcp"

  network_id        = var.network_id
  cidr              = "192.168.120.0/24"
  pool_start_offset = 100
  pool_end_offset   = 200
  dns_servers       = ["1.1.1.1", "8.8.8.8"]
  node_selector     = var.dhcp_node_selector
}
```

`network_id` is a `namespace/name` NAD reference, the same form produced by the
sibling `protected-network` module's `ids` output. Offsets apply to `cidr`, so
other IPv4 prefixes work when the pool offsets fit: for example, a `/28` needs
a smaller pool than 100–200. The public DNS resolvers above are example choices,
not standalone module defaults; use reachable, approved internal resolvers when
needed. Explicit DNS is necessary when pairing with `vlan-nat-gateway`, which
does not forward DNS.

## Inputs

| Name | Type | Required / default | Meaning |
| --- | --- | --- | --- |
| `network_id` | `string` | Required | Target NAD as `namespace/name` DNS-1123 labels. When `name_prefix` is omitted, the name must be at most 58 characters so derived resource names stay valid. |
| `cidr` | `string` | Required | IPv4 subnet served on the VLAN. The CIDR check permits `/30`, but gateway, server, and a non-broadcast lease pool together need `/29` or larger. |
| `pool_start_offset` | `number` | Required | First leasable host offset. Positive integer inside `cidr`, greater than both `gateway_offset` and `server_offset`. |
| `pool_end_offset` | `number` | Required | Last leasable host offset. Positive integer inside `cidr`, not the broadcast address, and >= `pool_start_offset`. |
| `node_selector` | `map(string)` | Required, non-empty | Pins the single DHCP Pod to nodes whose uplink carries this VLAN. |
| `gateway_offset` | `number` | `1` | Host offset advertised as the router. Only advertised, never created or verified. |
| `server_offset` | `number` | `2` | Host offset the Pod binds statically on `net1`. Must differ from `gateway_offset`. |
| `dns_servers` | `list(string)` | `null` | IPv4 resolvers advertised to clients. `null` advertises the gateway, which then must forward DNS. A non-null value must be a non-empty list. |
| `lease_time` | `string` | `"12h"` | `infinite`, or a non-zero 1-6 digit number followed by `s`, `m`, `h`, or `d`. |
| `domain` | `string` | `null` | Single DNS suffix advertised to clients; validation blocks multi-value and injected config. |
| `image` | `string` | pinned dnsmasq digest | Container image; must be non-empty. See image notes below. |
| `name_prefix` | `string` | `null` | ConfigMap/Deployment name prefix. `null` uses the NAD name. DNS-1123 label up to 58 characters. |
| `labels` | `map(string)` | `{}` | Extra labels; module-managed `app.kubernetes.io/name`, `instance`, and `managed-by` take precedence. |
| `resources` | `object` | `{}` | Optional `requests_cpu = "10m"`, `requests_memory = "32Mi"`, `limits_cpu = "200m"`, `limits_memory = "128Mi"`, so the Pod is not BestEffort. |

Default `image`:

```text
docker.io/jpillora/dnsmasq@sha256:34132cc95b1b8c124d2402b0da53995e68d2d46b8d0020d63cac9ecccb0e8008
```

This older public image is not a supply-chain policy or a guarantee of platform
compatibility. Verify its tools and architecture; mirror and scan an approved
immutable digest before use beyond a lab.

## Outputs

| Output | Meaning |
| --- | --- |
| `namespace` | Namespace parsed from `network_id`, shared by NAD and workload. |
| `network_name` | Target NAD name parsed from `network_id`. |
| `server_ip` | Static address bound on `net1`. |
| `gateway` | Gateway advertised to clients; not created or verified by this module. |
| `pool_start` | First address in the lease pool. |
| `pool_end` | Last address in the lease pool. |
| `dns_servers` | Effective resolvers advertised, after gateway defaulting. |
| `deployment_name` | Name of the Deployment running dnsmasq. |
| `dnsmasq_config` | Rendered configuration for review and troubleshooting. |

## Behavior and limitations / lifecycle

- Creates one ConfigMap and one Deployment named `<prefix>-dhcp` in the NAD's
  namespace, with `replicas = 1` and the `Recreate` strategy so two servers
  never share a static IP and pool. Rollouts therefore cause a brief outage.
- Startup verifies `dnsmasq` and `ip` exist, brings up `net1`, applies the
  static address, and executes dnsmasq in the foreground. dnsmasq serves DHCP
  only; its DNS listener is disabled.
- Probes check that `net1` holds the expected address and a UDP 67 listener
  exists. Both readiness and liveness use this check; repeated liveness
  failures restart the container, while readiness failures mark it unready. Probes do not prove Layer 2 reachability or correct lease delivery;
  validate with a disposable client after deployment and network changes.
- A configuration checksum annotation triggers Pod replacement when rendered
  dnsmasq settings change.
- Leases live in an `emptyDir`-backed `/tmp` file and do not survive Pod
  replacement. Clients keep addresses until renewal, and a silent client's
  address may be reassigned. This module exposes no reservation or persistence
  inputs; use a separate design with reservations or durable HA DHCP when stable
  assignment matters. Adding persistence requires deliberate
  ownership, backup, corruption-recovery, and rollout design.
- Validation prevents leasing the gateway or server addresses and rejects the
  broadcast address, but correctness of the advertised gateway, DNS, routing,
  and MTU is the caller's responsibility.
- Do not raise replicas: independent dnsmasq Pods sharing one pool issue
  conflicting leases. `node_selector` changes move the only server and cause an
  outage; a node failure removes DHCP for the VLAN.
- Deleting this module removes DHCP service. The NAD and its consumers are
  unaffected, but clients lose address renewal. Confirm no other DHCP server
  serves the VLAN to avoid conflicting offers.
- `harvester_network.route_dhcp_server_ip` only records an address as route
  metadata and does not deploy DHCP. Do not make NAD creation depend on this
  module's computed outputs; the NAD must exist first.

## Testing

Run from `modules/vlan-dhcp` with Terraform 1.9+:

```sh
terraform init -backend=false
terraform validate
terraform test
```

The suite uses a mocked Kubernetes provider and plan-only runs to check input
validation, derived addresses, rendered configuration, and workload settings.
It does not create resources or prove DHCP works on a live VLAN. Provider
installation still requires registry access or a configured local mirror/cache.
