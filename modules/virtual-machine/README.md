# virtual-machine

## Purpose and scope

Creates exactly one Harvester VM, its VM-owned disks, and an optional cloud-init
Secret. Attaches externally managed persistent PVCs without owning their lifecycle.
Does not create namespaces, images, networks, or persistent data volumes.

## Requirements and providers

| Dependency | Declared constraint / requirement |
| --- | --- |
| Terraform | `>= 1.3` declared; the built-in `terraform_data` resource requires 1.4+. Mocked tests require 1.7+. |
| `harvester/harvester` | `= 1.9.0` |

Configure the Harvester provider in the caller. Referenced namespaces, images,
networks, and PVCs must exist; attached PVCs must be in the VM namespace. Guests
need compatible firmware, drivers, and cloud-init support. Lease reporting depends
on guest/network readiness; VM readiness is not proof of application readiness.

## Default context

Defaults allocate 2 vCPUs, `4Gi` RAM, and a VM-owned `40Gi` virtio root disk in
`default`, with EFI enabled, Secure Boot disabled, and `RerunOnFailure`. This is
a starting point for a small general-purpose guest, not a workload sizing guarantee.
No image is selected by default: the root disk is empty. Supply a bootable image
compatible with the host architecture, EFI, and virtio, or arrange OS installation.
Cloud-init is enabled but its default payload creates no access credentials or tools.

The default NIC uses management-network masquerade without lease waiting; it is
not a bridged VLAN attachment or an inbound-access configuration. Override networking
for VLAN access, firmware for image requirements, and sizing for the workload.
Root disks are disposable; attach independently managed PVCs for retained data.

## Usage

Caller configuration snippet, **not a standalone root module**: declare and supply
all referenced variables and configure the provider separately. The source path
assumes the caller is at the **repository root**; adjust it elsewhere.

This example chooses the name `utility-vm` and uses the default sizing and management
network. Supply cloud-init appropriate to your image, including guest access settings.

```hcl
module "machine" {
  source = "./modules/virtual-machine"

  name       = "utility-vm"
  root_image = var.root_image_id
  cloudinit = {
    user_data = var.cloudinit_user_data
  }
}
```

For a bridged VLAN, add this argument inside the module call. The named network
must already exist and provide guest addressing; lease waiting is an example choice.

```hcl
network_interfaces = [{
  name           = "nic-1"
  network_name   = var.network_id
  wait_for_lease = true
}]
```

For retained data, add `persistent_disks = { data = { existing_volume_name = var.data_pvc_name } }`.
Manage that PVC independently, for example with `../protected-volume`, in the VM's
namespace; pass a PVC **name**, not a qualified ID.

## Inputs

| Name | Type | Required / default | Meaning |
| --- | --- | --- | --- |
| `name` | `string` | Required | Exact VM name; lowercase DNS-compatible label, at most 63 characters. |
| `namespace` | `string` | `"default"` | Existing namespace; lowercase DNS-label syntax. |
| `description` | `string` | `null` | VM description. |
| `labels` | `map(string)` | `{}` | Kubernetes labels; caller overrides common labels, but instance label is the VM name. |
| `tags` | `map(string)` | `{}` | Harvester tags; `ssh-user` is metadata, not guest user creation. |
| `cpu` | `number` | `2` | Positive integer vCPU count. |
| `cpu_model` | `string` | `null` | Optional KubeVirt CPU model. |
| `memory` | `string` | `"4Gi"` | Memory limit as a supported Kubernetes quantity. |
| `resource_requests` | `object` | `null` | Optional string `cpu` and `memory`, each defaulting to null; omission delegates requests to Harvester's overcommit webhook. |
| `machine_type` | `string` | `null` | Optional machine type. |
| `set_hostname_from_instance_name` | `bool` | `true` | Set guest hostname from VM name. |
| `reserved_memory` | `string` | `null` | Optional reserved memory quantity. |
| `cpu_pinning` | `bool` | `false` | Dedicated CPU placement; needs node CPU-manager support. |
| `isolate_emulator_thread` | `bool` | `false` | Additional dedicated emulator CPU; requires `cpu_pinning`. |
| `node_selector` | `map(string)` | `{}` | Scheduling label constraints. |
| `efi` | `bool` | `true` | Enable EFI firmware. |
| `secure_boot` | `bool` | `false` | Enable Secure Boot/SMM; requires EFI. |
| `tpm` | `bool` | `false` | Attach a virtual TPM. |
| `run_strategy` | `string` | `"RerunOnFailure"` | One of `Always`, `Manual`, `Halted`, `RerunOnFailure`. |
| `restart_after_update` | `bool` | `true` | Restart after updates; effective for `Always` and `RerunOnFailure`. |
| `create_initial_snapshot` | `bool` | `false` | Asynchronously create `<vm-name>-initial` after first readiness. |
| `root_image` | `string` | `null` | Harvester image `name` or `namespace/name`; null creates an empty root disk. |
| `root_disk_size` | `string` | `"40Gi"` | Root disk quantity. |
| `root_disk_bus` | `string` | `"virtio"` | `virtio`, `sata`, or `scsi`. |
| `root_disk_boot_order` | `number` | `1` | Non-negative integer; zero leaves order unset. |
| `root_disk_storage_class_name` | `string` | `null` | Empty-root StorageClass; must be omitted with `root_image`. |
| `ephemeral_disks` | `map(object)` | `{}` | VM-owned disks keyed by device name; schema below. |
| `persistent_disks` | `map(object)` | `{}` | External PVC attachments keyed by device name; schema below. |
| `cdroms` | `map(object)` | `{}` | Optional image-backed CD-ROMs keyed by device name. |
| `network_interfaces` | `list(object)` | `[{ name = "nic-1" }]` | At least one interface, with unique names; schema below. |
| `cloudinit` | `object` | `{}` | Defaults: `enabled = true`, `type = "noCloud"`, `user_data = "#cloud-config\n"`, `network_data = ""`. Type also accepts `configDrive`. |
| `ssh_keys` | `list(string)` | `[]` | Harvester KeyPair IDs (`namespace/name`); requires enabled cloud-init. Public keys must already be in Secret-backed `user_data` under `ssh_authorized_keys`. |
| `inputs` | `list(object)` | `[]` | Input devices: required string `name`, optional string `type = "tablet"`, `bus = "usb"`. |
| `host_devices` | `list(object)` | `[]` | Required strings `name` and `device_name`; latter is a cluster-exposed Kubernetes resource name. |
| `timeouts` | `object` | `{}` | Optional strings: `create = "10m"`, `read = "2m"`, `update = "10m"`, `delete = "10m"`. |

Nested disk attributes (unlisted optional values default to null):

| Input | Required attributes | Optional attributes and defaults |
| --- | --- | --- |
| `ephemeral_disks` | `size` (string quantity) | `bus = "virtio"`, `cache_mode` (string), `boot_order = 0`, `image` (string), `storage_class_name` (string), `volume_mode = "Block"`, `access_mode = "ReadWriteMany"`. |
| `persistent_disks` | `existing_volume_name` (non-empty DNS-compatible PVC name) | `bus = "virtio"`, `cache_mode` (string), `boot_order = 0`, `hot_plug = false`. |
| `cdroms` | None | `image` (string), `bus = "sata"`, `boot_order = 0`. |

Disk keys must be lowercase DNS-compatible names, unique across all three maps,
and cannot be `rootdisk` or `cloudinitdisk`. Duplicate persistent PVC references
are rejected. Disk buses accept `virtio`, `sata`, `scsi`; CD-ROMs accept only
`sata` or `scsi`. Cache modes accept `none`, `writeback`, `writethrough`. Images
use `name` or `namespace/name`; omit StorageClass for image-backed disks.
Ephemeral volume modes are `Block` or `Filesystem`; access modes are
`ReadWriteOnce`, `ReadOnlyMany`, or `ReadWriteMany`.

Each network interface requires string `name`; optional attributes are
`network_name`, `type`, and `mac_address` (strings, null), `model = "virtio"`,
`wait_for_lease = false`, and `boot_order = 0`. Empty/omitted network name selects
the management network with provider-default masquerade; named networks default
to bridge. Explicit type is `bridge` or `masquerade`. Models: `virtio`, `e1000`,
`e1000e`, `ne2k_pco`, `pcnet`, `rtl8139`.

## Outputs

| Output | Meaning |
| --- | --- |
| `name` | VM name. |
| `id` | Resource ID (`namespace/name`). |
| `cpu` | Assigned vCPU cores. |
| `memory` | Assigned memory. |
| `node_name` | Scheduled Harvester node; empty before scheduling. |
| `state` | Provider-derived VM state, not guest bootstrap/application health. |
| `run_strategy` | Configured KubeVirt run strategy. |
| `network_interfaces` | Interfaces including reported IP and interface names. |
| `primary_ip_address` | First interface IP; empty until reported. |
| `cloudinit_secret_name` | Secret name, or null when cloud-init is disabled. |

## Behavior and limitations / lifecycle

- Root, ephemeral, and CD-ROM disks use `auto_delete = true`. Persistent PVC
  attachments use `auto_delete = false`; this is not protection against deletion
  by another resource, identity, or API operation. Keep backups and independent
  volume controls. Never keep unique data on root or ephemeral disks.
- Storage and cloud-init fingerprints trigger VM replacement on configuration
  changes, including persistent attachment changes. Replacement keeps the name,
  deletes VM-owned disks, and reattaches retained PVCs; there is no
  `create_before_destroy`. Even `hot_plug` changes participate in the fingerprint.
- Raw `disk` drift is ignored to avoid provider 1.9.0's generated `cloudinitdisk`
  diff. Fingerprints cover caller-configurable disk fields, but this does not
  reconcile arbitrary out-of-band disk drift.
- Cloud-init is first-boot configuration. Enabled cloud-init creates
  `<name>-cloudinit`; payload changes replace the VM rather than merely updating
  a running guest. Payloads are stored in Terraform state and a Kubernetes Secret;
  the input is not marked sensitive. Avoid plaintext credentials and protect
  state, plans, logs, and Secret access. Hashing replacement triggers does not
  remove the underlying payload from state.
- Image lookups determine image-backed StorageClasses. The module does not
  install a guest agent, provision DHCP, guarantee storage readiness, or make
  shared filesystems safe. Initial snapshots are asynchronous, not a backup policy.

## Testing

Run from `modules/virtual-machine` with Terraform 1.7+:

```sh
terraform init -backend=false
terraform validate
terraform test
```

Tests use a mocked provider to check storage, validation, and cloud-init behavior.
They do not prove live VM boot, guest readiness, or disk retention during actual
replacement. Provider installation requires registry access or a configured mirror/cache.
