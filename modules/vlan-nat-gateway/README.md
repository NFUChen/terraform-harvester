# vlan-nat-gateway

## Purpose and scope

Runs one Pod that provides IPv4 NAT egress for a single existing Harvester VLAN
NetworkAttachmentDefinition (NAD). The Pod holds the gateway address on its
Multus interface `net1`, forwards traffic out the Kubernetes default interface
`eth0`, and installs MASQUERADE, stateful FORWARD, and TCP MSS clamping rules.

The module does not create NADs, namespaces, Services, DHCP, DNS, firewall
policy beyond the rules below, or inbound port forwarding. It is a lab/sandbox
utility: a single Pod with no HA and no persistent connection state.

## Requirements and providers

| Dependency | Declared constraint / requirement |
| --- | --- |
| Terraform | `>= 1.3` in `versions.tf`; this is not a verified compatibility guarantee. Tested with Terraform 1.15. |
| `hashicorp/kubernetes` | `~> 2.38` (>= 2.38.0, < 3.0.0), configured by the caller |

Cluster requirements: the target NAD must already exist in the namespace parsed
from `network_id`; Multus must attach it as `net1` with no IPAM; the selected
nodes must carry the VLAN uplink and have working Pod-network egress. A
short-lived **privileged** init container enables `net.ipv4.ip_forward` in the
Pod network namespace, and the long-running container runs as UID 0 with
`NET_ADMIN` and `NET_RAW`, so cluster admission policy must permit both. The
image must provide `/bin/sh`, `ip`, `iptables`, `sysctl`, and `grep`. Deploy
only in a platform-controlled namespace.

## Default context

The gateway defaults to host offset 1 of the supplied CIDR, matching the offset
`../vlan-dhcp` advertises by default. The NAD, CIDR, and node selector are
required; namespace and workload name derive from `network_id`. The gateway
container's requests are fixed at `10m` CPU / `32Mi` memory, with limits of
`200m` / `128Mi`; these are not a throughput guarantee and have no input override.
Override `gateway_offset` if offset 1 is unavailable, and update client routes or
DHCP accordingly. Override `image` for an approved compatible digest.

The CIDR is used both for the gateway address and as the NAT/FORWARD rule scope,
so it must match the VLAN subnet. This provides outbound IPv4 egress only: it adds
no DNS, inbound port forwarding, or restriction policy, and VLAN clients still need
addresses and a default route pointing at the gateway. It is a single Pod without
HA or persisted connection state, suitable for lab/sandbox VLANs where egress
interruptions on rollout or node failure are acceptable.

## Usage

Caller configuration snippet, **not a standalone root module**: declare and
supply the referenced variables and configure the Kubernetes provider
separately. The source path below assumes the caller is at the **repository
root**; adjust it for a caller located elsewhere.

The CIDR below is illustrative and makes the gateway `192.168.120.1`. It must
match the VLAN subnet, and that address must be free and reserved.

```hcl
module "vlan_nat_gateway" {
  source = "./modules/vlan-nat-gateway"

  network_id    = var.network_id
  cidr          = "192.168.120.0/24"
  node_selector = var.gateway_node_selector
}
```

`network_id` is a `namespace/name` NAD reference, the same form produced by the
sibling `protected-network` module's `ids` output. The gateway address is
`cidrhost(cidr, gateway_offset)`. Clients need that address as their default
route, their own VLAN addresses, and separately provided DNS; pair this module
with a DHCP source using the same CIDR and gateway offset, or configure clients
statically.

## Inputs

| Name | Type | Required / default | Meaning |
| --- | --- | --- | --- |
| `network_id` | `string` | Required | Target NAD as `namespace/name` DNS-1123 labels. Also determines the workload namespace. |
| `cidr` | `string` | Required | IPv4 VLAN subnet. Used for the gateway address and as the NAT/FORWARD rule source and destination. |
| `node_selector` | `map(string)` | Required, non-empty | Pins the single gateway Pod to nodes whose uplink carries this VLAN. |
| `gateway_offset` | `number` | `1` | Positive integer host offset for the gateway address inside `cidr`. |
| `image` | `string` | pinned netshoot digest | Container image for both the init and gateway containers; must contain the required networking tools. |
| `name_prefix` | `string` | `null` | Deployment name prefix. `null` uses the NAD name. Unvalidated, so keep it a short DNS-1123 label or the Kubernetes API rejects the `<prefix>-nat` object. |
| `labels` | `map(string)` | `{}` | Extra labels; module-managed `app.kubernetes.io/name`, `instance`, and `managed-by` take precedence. |

Resource requests and limits are fixed in the module and not exposed as inputs.
`image` is not validated as non-empty, and `cidr` is accepted when offset 1
exists, so a `/31` passes validation while offering no usable lease range for a
paired DHCP service.

Default `image`:

```text
docker.io/nicolaka/netshoot@sha256:a20c2531bf35436ed3766cd6cfe89d352b050ccc4d7005ce6400adf97503da1b
```

This public troubleshooting image is not a supply-chain policy or a guarantee of
platform compatibility. Verify its tools and architecture; mirror and scan an
approved immutable digest before use beyond a lab.

## Outputs

| Output | Meaning |
| --- | --- |
| `gateway_ip` | Gateway address bound on `net1`. |
| `deployment_name` | Name of the Deployment running the gateway. |
| `namespace` | Namespace parsed from `network_id`. |
| `network_name` | Target NAD name parsed from `network_id`. |

## Behavior and limitations / lifecycle

- Creates one Deployment named `<prefix>-nat` in the NAD's namespace, with
  `replicas = 1` and the `Recreate` strategy. Rollouts therefore cause an
  egress outage.
- The init container sets `net.ipv4.ip_forward=1` for the Pod network
  namespace, because that setting is namespaced and defaults to disabled.
- Startup verifies the tools and forwarding are present, brings up `net1`,
  applies the gateway address, then installs idempotently checked rules:
  MASQUERADE for `cidr` out `eth0`; TCP MSS clamped to the path MTU on
  forwarded SYNs; outbound FORWARD from `net1` to `eth0` for `cidr`; and return
  FORWARD for ESTABLISHED/RELATED traffic. MSS clamping prevents stalls when
  the egress MTU is smaller than the VLAN MTU, which otherwise appears as
  successful small requests but hanging TLS handshakes.
- Readiness checks the `net1` address, MASQUERADE, and MSS rule; liveness
  checks IP forwarding and MASQUERADE. Neither checks the FORWARD rules.
  Repeated liveness failures restart the container; readiness failures only
  mark it unready. These probes do not prove end-to-end connectivity.
  Validate with a disposable client after deployment and network changes.
- Rules apply inside the Pod network namespace only and are rebuilt on each
  start. NAT and conntrack state is not persisted, so existing connections break
  on Pod replacement or node failure.
- Do not raise replicas: multiple Pods would contend for one gateway address.
  Real HA NAT requires a floating address, coordinated failover, and
  connection-state design rather than extra replicas. `node_selector` changes
  move the only gateway and cause an outage.
- This module has no Terraform lifecycle protection: ordinary applies can
  update or replace the Deployment, and removing the module deletes it. Deleting
  it removes VLAN egress while leaving the NAD and its consumers in place. Use
  CI/RBAC and approval controls where unplanned egress loss is unacceptable.
- Only the listed rules are added; the module does not establish default-deny
  policies or remove other rules. It configures no inbound port forwarding,
  DNS, traffic logging, or per-destination restrictions and is not a security
  firewall. Actual reachability also depends on CNI, upstream routes, and policy.
- Address validation is limited: out-of-range offsets fail during `cidrhost`
  evaluation, but broadcast addresses and conflicts with existing hosts are not
  explicitly rejected. Reserve a usable, unique gateway address before apply.

## Testing

Run from `modules/vlan-nat-gateway` with Terraform 1.7+ for mocked providers
(verified with 1.15):

```sh
terraform init -backend=false
terraform validate
terraform test
```

The suite uses a mocked Kubernetes provider and plan-only runs to check input
validation, the derived gateway address, rollout strategy, NAT and MSS clamping
rules, and the privileged init container. It does not create resources or prove
egress works on a live VLAN. Provider installation still requires registry
access or a configured local mirror/cache.
