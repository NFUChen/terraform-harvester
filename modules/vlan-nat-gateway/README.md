# vlan-nat-gateway

Lab/sandbox single-Pod IPv4 NAT gateway for a Harvester VLAN NAD. The Pod has:

- `net1`: Multus interface on the VLAN, assigned the gateway IP;
- `eth0`: Kubernetes default network, used as the NAT egress;
- iptables MASQUERADE and stateful FORWARD rules.

## Usage

```hcl
module "v100_nat" {
  source = "./modules/vlan-nat-gateway"

  network_id = module.networks.ids["v100"]
  cidr       = "172.16.100.0/24"

  node_selector = {
    "kubernetes.io/hostname" = "local-harvester"
  }
}
```

Gateway defaults to `cidrhost(cidr, 1)` (`172.16.100.1`). Configure DHCP with
the same CIDR and advertise public/internal DNS explicitly:

```hcl
module "v100_dhcp" {
  source = "./modules/vlan-dhcp"

  network_id = module.networks.ids["v100"]
  cidr       = "172.16.100.0/24"

  pool_start_offset = 100
  pool_end_offset   = 200
  dns_servers       = ["1.1.1.1", "8.8.8.8"]

  node_selector = {
    "kubernetes.io/hostname" = "local-harvester"
  }
}
```

## Runtime design

The Pod network namespace defaults to `net.ipv4.ip_forward=0` even when the
RKE2 node has forwarding enabled. A short-lived privileged init container runs:

```sh
sysctl -w net.ipv4.ip_forward=1
```

The long-running gateway container is non-privileged with only `NET_ADMIN` and
`NET_RAW`. It installs:

```sh
iptables -t nat -A POSTROUTING -s <cidr> -o eth0 -j MASQUERADE
iptables -t mangle -A FORWARD -i net1 -o eth0 \
  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -A FORWARD -i net1 -o eth0 -s <cidr> -j ACCEPT
iptables -A FORWARD -i eth0 -o net1 -d <cidr> \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

## MTU and MSS clamping

The VLAN side runs at MTU 1500 while the Pod-network egress (`eth0`) is
smaller — 1450 on Harvester. Without MSS clamping, a VM advertises an MSS
derived from its own 1500-byte link, the reply exceeds the egress MTU, and the
resulting `Frag needed` ICMP is frequently dropped upstream. The connection
then completes its TCP handshake and stalls on the first large payload.

The symptom is misleading: small requests such as `apt` metadata succeed while
TLS handshakes to endpoints with large certificate chains fail with
`SSL connection timeout`. The clamp rule above removes this PMTU black hole by
rewriting the MSS on forwarded SYNs to match the real path MTU.

## Image

Pinned, externally verified image:

```text
docker.io/nicolaka/netshoot@sha256:a20c2531bf35436ed3766cd6cfe89d352b050ccc4d7005ce6400adf97503da1b
```

Verified on amd64 to contain `ip`, `iptables` (nf_tables backend), `nft`,
`sysctl`, and `conntrack`. Production should mirror and scan it internally.

## Availability and security

This module is lab/sandbox only:

- one Pod and one gateway IP;
- `Recreate` rollout causes an outage;
- restart loses conntrack/NAT sessions;
- node failure removes VLAN egress;
- privileged init container is required to enable forwarding;
- Pod must be pinned to a node whose VLANConfig/uplink carries the VLAN.

Do not scale replicas above one. HA NAT requires VRRP/floating IP, coordinated
failover, and connection-state design—not ordinary Kubernetes replicas.

## Verified integration

Applied on VLAN 100 in the Harvester cluster and verified:

```text
gateway Pod: Ready 1/1, restart count 0
net1:        172.16.100.1/24
ip_forward:  1
MASQUERADE:  present
FORWARD:     outbound + ESTABLISHED/RELATED return rules present
```

A temporary client Pod on the same NAD used `172.16.100.250/24`, default route
`172.16.100.1`, and completed:

```text
ping 172.16.100.1: success
ping 8.8.8.8:       success
DNS via 1.1.1.1:    success
```

The temporary client was deleted afterward; the gateway/DHCP are retained as
managed `fundamental` resources.
