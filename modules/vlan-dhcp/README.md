# vlan-dhcp

Runs one lightweight dnsmasq Deployment per Harvester VLAN so VMs attached to
the VLAN can obtain addresses without consuming the host/home-network DHCP
pool.

**Scope:** this module is for lab, sandbox, and non-critical VLANs. Its single
Pod and ephemeral lease database are intentionally simple and are not a
production HA DHCP design. Pod restart can cause duplicate allocation when
silent clients continue using leases the new server no longer remembers.

The DHCP server is a Kubernetes Pod attached to the same Harvester
NetworkAttachmentDefinition (NAD) through Multus. Harvester's generated VLAN
NAD uses bridge CNI with `ipam: {}`, so Multus creates a Layer-2 VLAN interface
without assigning an address; the container binds a deterministic static
address and serves DHCP directly on that interface.

## Architecture

```text
Harvester ClusterNetwork/VLANConfig
        │
protected-network module
        │ creates NAD (bridge + VLAN, no IPAM)
        ├─────────────────────┐
        │                     │
virtual-machine module   vlan-dhcp module
VM nic -> VLAN bridge    dnsmasq net1 -> same VLAN bridge
        │                     │
        └──── DHCP broadcast ─┘
```

One module call serves exactly one VLAN. This keeps failure domains isolated:
restarting DHCP for database VLAN does not affect production VLAN.

## Usage

```hcl
module "networks" {
  source = "./modules/protected-network"

  namespace            = "harvester-public"
  cluster_network_name = "workload"

  networks = {
    "database-v110" = {
      vlan_id = 110
    }
  }
}

module "database_dhcp" {
  source = "./modules/vlan-dhcp"

  network_id = module.networks.ids["database-v110"]
  cidr       = "172.16.110.0/24"

  pool_start_offset = 100
  pool_end_offset   = 200

  node_selector = {
    "kubernetes.io/hostname" = "local-harvester"
  }
}
```

Derived values:

```text
gateway:    172.16.110.1  (gateway_offset = 1)
DHCP server:172.16.110.2  (server_offset = 2)
pool start: 172.16.110.100
pool end:   172.16.110.200
DNS:        172.16.110.1  (defaults to gateway)
```

The module advertises the gateway; it does not create or verify that gateway.
The router/firewall for the VLAN must already own `.1` and provide routing.
Because DNS defaults to the gateway, that gateway must also provide DNS
forwarding; otherwise pass explicit `dns_servers`.

## Arbitrary IPv4 CIDRs

Pool boundaries use host offsets instead of literal IP addresses. This allows
the module to prove ordering and subnet membership for `/24`, `/25`, `/28`,
and other IPv4 subnets:

```hcl
module "small_vlan_dhcp" {
  source = "./modules/vlan-dhcp"

  network_id = module.networks.ids["small-v120"]
  cidr       = "172.16.120.0/28"

  pool_start_offset = 8
  pool_end_offset   = 14

  dns_servers = ["1.1.1.1", "8.8.8.8"]

  node_selector = {
    "kubernetes.io/hostname" = "local-harvester"
  }
}
```

The module validates:

- valid IPv4 CIDR with room for gateway/server;
- integer offsets inside the subnet;
- pool start <= pool end;
- pool starts after gateway/server, so neither address can be leased;
- pool end is not the broadcast address;
- gateway and DHCP server use distinct addresses;
- DNS entries are valid IPv4 addresses.

## VM usage

```hcl
module "database_vm" {
  source = "./modules/virtual-machine"

  name_prefix = "database"
  root_image  = data.harvester_image.ubuntu_noble.id

  network_interfaces = [{
    name           = "nic-1"
    type           = "bridge"
    model          = "virtio"
    network_name   = module.networks.ids["database-v110"]
    wait_for_lease = true
  }]

  cloudinit = {
    user_data = <<-YAML
      #cloud-config
      packages:
        - qemu-guest-agent
      runcmd:
        - systemctl enable --now qemu-guest-agent
    YAML
  }
}
```

For a non-management Multus network, Terraform needs qemu-guest-agent to
observe the guest IP when `wait_for_lease = true`.

## Kubernetes workload design

The module creates:

- one ConfigMap containing generated `dnsmasq.conf`;
- one Deployment with exactly one replica;
- `Recreate` rollout strategy so two servers never race for the same static IP
  and lease pool;
- Multus JSON annotation requesting the target NAD as interface `net1`;
- static VLAN IP configured by `ip addr replace` before dnsmasq starts;
- an ephemeral lease file under `/tmp`;
- no ServiceAccount token;
- read-only root filesystem;
- capabilities limited to `NET_ADMIN`, `NET_RAW`, `NET_BIND_SERVICE`, plus
  `SETUID`/`SETGID` required for dnsmasq to drop from root to `nobody` after
  configuring the interface and binding DHCP sockets;
- resource requests/limits so the server is not a BestEffort Pod;
- required `node_selector`, preventing rescheduling onto a node without the
  VLANConfig/uplink;
- readiness verifies `net1` has the expected server IP and dnsmasq is listening
  on UDP 67; liveness verifies the dnsmasq PID remains alive.

Readiness does not prove Layer-2 traffic reaches clients. A disposable VM DHCP
canary remains required after deployment and network changes.

`NET_ADMIN` is required to assign the static address to the no-IPAM Multus
interface. This is more privileged than a normal application Pod; deploy it
only in a platform-controlled namespace/state.

## Container image verification

Default image:

```text
docker.io/jpillora/dnsmasq@sha256:34132cc95b1b8c124d2402b0da53995e68d2d46b8d0020d63cac9ecccb0e8008
```

It was pulled and executed on an external amd64 Linux host and verified to
contain:

```text
/usr/sbin/dnsmasq — version 2.80
/sbin/ip          — BusyBox 1.29.3
/bin/sh           — BusyBox
uid               — 0
```

The container startup command checks `dnsmasq` and `ip` exist and fails fast
otherwise. For production, mirror this digest into an internal registry,
scan it, and override `image` with the internal immutable digest. The upstream
image is old and built from an Alpine edge base, so the public digest should
not be treated as long-term supply-chain policy.

## Lease behavior

Leases are intentionally ephemeral (`/tmp/dnsmasq.leases`). After Pod
replacement, clients retain their current address until renewal; dnsmasq has
no prior lease database and may allocate that address again if a client is
silent. In a small lab this is commonly acceptable, but understand the risk.

For environments that require stable assignments across DHCP Pod restarts:

- add static DHCP reservations by MAC address; or
- build a separate persistent/HA DHCP design (for example Kea with a durable
  lease backend).

Do not attach a protected volume to this module without first designing file
ownership, backup, corruption recovery, and rollout semantics.

## Availability limits

This is a single DHCP server per VLAN:

- Pod restart causes a temporary DHCP outage;
- existing leases continue functioning until renewal;
- `Recreate` prevents overlap but introduces a short gap during config/image
  rollout;
- no DHCP failover protocol is configured;
- `node_selector` is mandatory and must target a node whose ClusterNetwork
  VLANConfig/uplink carries the VLAN. Changing it moves the only DHCP server
  and causes an outage during rollout.

For critical networks, use a real HA DHCP architecture instead of increasing
replicas in this module. Two independent dnsmasq replicas sharing a pool would
issue conflicting leases.

## Relationship to `harvester_network.route_dhcp_server_ip`

This module creates the actual DHCP service. The `harvester_network`
`route_dhcp_server_ip` field only records the IP of an existing DHCP server for
Harvester network-controller route/connectivity logic; it does not deploy one.

If desired, the root configuration may set the protected-network route to
`auto` and document this module's `server_ip`, but avoid a circular dependency:
network creation must happen before the DHCP Deployment can attach to it. Do
not make the NAD depend on a computed DHCP Pod value.

## Verified sandbox integration

The module was applied to a temporary `mgmt` ClusterNetwork NAD on VLAN 4094
(`192.0.2.0/24`) and validated end to end:

```text
Pod:          Ready 1/1, restart count 0
net1:         192.0.2.2/24
DHCP socket:  UDP 0.0.0.0:67
dnsmasq:      syntax check OK
DORA:         DISCOVER -> OFFER -> REQUEST -> ACK
leased IP:    192.0.2.175
options:      netmask /24, gateway 192.0.2.1, DNS 192.0.2.1, lease 12h
```

Two runtime issues were found and fixed during this test:

- read-only root filesystem required disabling the default PID file with
  `pid-file=`;
- after dropping all Linux capabilities, dnsmasq required `SETUID` and
  `SETGID` to drop privileges from root to `nobody` after configuring the
  interface and binding sockets.

A disposable BusyBox `udhcpc` client Pod on the same Multus NAD completed the
full DHCP exchange. All temporary Pods, Deployment, ConfigMap, and NAD were
removed afterward and cleanup was verified.

## Sandbox rollout checklist

Before using on another VLAN:

1. Create a disposable VLAN/NAD with physical trunk and gateway configured.
2. Deploy this module.
3. Confirm the Pod has `net1` and the expected static server IP:

   ```sh
   kubectl -n <namespace> exec deploy/<name>-dhcp -- ip addr show net1
   ```

4. Confirm dnsmasq is listening on UDP 67 and logs DHCP discover/offer:

   ```sh
   kubectl -n <namespace> logs deploy/<name>-dhcp
   ```

5. Attach a disposable VM using DHCP and verify address, gateway, DNS, and
   egress.
6. Restart the DHCP Pod and verify existing/new clients recover as expected.
7. Restart/migrate the VM and verify Multus + DHCP still work on target nodes.
8. Confirm there is no other DHCP server on the VLAN (rogue/duplicate DHCP).

## Outputs

| Output | Meaning |
| --- | --- |
| `namespace` | Namespace shared with the NAD |
| `network_name` | Target NAD name |
| `server_ip` | Static IP bound on dnsmasq `net1` |
| `gateway` | Gateway advertised to clients |
| `pool_start` / `pool_end` | Computed lease boundaries |
| `dns_servers` | Advertised DNS servers |
| `deployment_name` | Kubernetes Deployment name |
| `dnsmasq_config` | Rendered config for review/troubleshooting |

## Verification

```sh
terraform fmt -recursive -check
terraform validate
terraform test
```
