---
name: harvester-virtualmachine
description: Harvester Terraform virtual machine management using harvester_virtualmachine, KubeVirt VM/VMI, disks, images, PVCs, networks, cloud-init, SSH keys, CPU/memory, EFI/Secure Boot/TPM, passthrough devices, imports, lifecycle, or stuck VM troubleshooting. Use whenever a user asks to create, inspect, migrate, update, debug, or generate Terraform for a Harvester VM, even if they only mention VM boot, guest IP, ISO installation, qcow2 image, hot-plug disk, VLAN NIC, qemu-guest-agent, cloud-init, CPU pinning, initial snapshot, or restart behavior.
compatibility: Requires Terraform with the harvester/harvester provider, Harvester kubeconfig access, and matching Harvester/provider versions.
metadata:
  domain: harvester
  resource: harvester_virtualmachine
---

# Harvester Virtual Machine

Use this skill to generate and troubleshoot minimal, correct Terraform for Harvester VMs. The resource creates a KubeVirt `VirtualMachine`, related PVC templates, networks, and optional cloud-init volumes; runtime status comes from the matching `VirtualMachineInstance` (VMI).

## First determine the intent

Collect only missing information:

1. Operation: create, inspect, import, resize/update, stop/start, attach storage/network/device, or troubleshoot.
2. Identity: Terraform label, Kubernetes `name`, and `namespace`.
3. Compute: vCPU, memory, optional requests, CPU model/pinning, machine type, node selector.
4. Boot mode: image disk, ISO plus root disk, existing PVC, or container disk; EFI/Secure Boot/TPM requirements.
5. Networking: management or VLAN network, interface model/type, lease waiting, optional MAC/boot order.
6. Guest initialization: inline cloud-init, base64, Secret, SSH keys, hostname.
7. Lifecycle: run strategy, restart after updates, auto-delete disks, initial snapshot.

Do not invent image IDs, network IDs, storage classes, PVCs, SSH keys, device resource names, or secrets. Ask for required values.

## Implementation workflow

1. Inspect existing provider version constraints and related `harvester_image`, `harvester_network`, `harvester_volume`, `harvester_ssh_key`, and cloud-init resources.
2. Follow repository conventions for variables, names, labels, and dependencies.
3. Define at least one `disk` and one `network_interface`; both are provider-required.
4. Use `run_strategy`; do not generate deprecated `start` for new code.
5. Model each disk with exactly one backing source where applicable.
6. Select one cloud-init representation per user/network data payload; avoid duplicating inline, base64, and Secret values.
7. Add appropriate timeouts when waiting for guest leases, image clones, or slow startup.
8. Run `terraform fmt` and `terraform validate`. Run `terraform plan` only when backend/credentials are available and the user permits it.
9. Explain mutable updates and whether `restart_after_update` is needed for the guest to receive them.

## Minimal image-backed VM

```hcl
resource "harvester_virtualmachine" "ubuntu" {
  name      = "ubuntu-01"
  namespace = "default"

  cpu    = 2
  memory = "4Gi"

  run_strategy         = "RerunOnFailure"
  restart_after_update = true

  network_interface {
    name           = "nic-1"
    wait_for_lease = true
  }

  disk {
    name        = "rootdisk"
    type        = "disk"
    bus         = "virtio"
    size        = "40Gi"
    boot_order  = 1
    image       = harvester_image.ubuntu.id
    auto_delete = true
  }

  cloudinit {
    user_data = <<-YAML
      #cloud-config
      hostname: ubuntu-01
    YAML
  }

  timeouts {
    create = "10m"
    update = "10m"
  }
}
```

The default management NIC uses masquerade when `network_name` is empty. A named Harvester network defaults to bridge.

## ISO installation pattern

```hcl
resource "harvester_virtualmachine" "installer" {
  name      = "installer"
  namespace = "default"

  cpu    = 4
  memory = "8Gi"

  efi          = true
  secure_boot  = false
  run_strategy = "RerunOnFailure"

  network_interface {
    name = "nic-1"
  }

  disk {
    name        = "rootdisk"
    type        = "disk"
    bus         = "virtio"
    size        = "80Gi"
    boot_order  = 2
    auto_delete = true
  }

  disk {
    name        = "install-media"
    type        = "cd-rom"
    bus         = "sata"
    image       = harvester_image.installer_iso.id
    size        = "10Gi"
    boot_order  = 1
    auto_delete = true
  }
}
```

After installation, changing/removing install media or boot order may require a restart. Prefer explicit boot orders only where needed; `0` means unset.

## Disk source rules

For each disk choose one path:

| Source | Fields | Notes |
|---|---|---|
| New PVC from image | `image`, usually `size` | Image identifier is namespace/name; storage class must match image storage class |
| New empty PVC | `size`, optional storage/access/volume mode | Uses default Harvester storage class if omitted |
| Existing PVC | `existing_volume_name` | Provider does not create it; use `auto_delete = false` |
| Container disk | `container_image_name` | KubeVirt container disk, not Harvester image |
| Empty CD-ROM | `type = "cd-rom"`, no source | No volume prepared |

Defaults derived by the provider:

- disk type: `disk`
- bus: CD-ROM → `sata`; hot-plug disk → `scsi`; otherwise → `virtio`
- newly created PVC volume mode: `Block`
- newly created PVC access mode: `ReadWriteMany`
- size: Harvester builder default when empty

Supported buses: `virtio`, `sata`, `scsi`. Supported cache modes: `none`, `writeback`, `writethrough`. Supported volume modes: `Block`, `Filesystem`; access modes: `ReadWriteOnce`, `ReadOnlyMany`, `ReadWriteMany`.

`storage_class_name` cannot override an image's storage class. Set the desired storage class when creating the image instead.

### Disk deletion safety

- Set `auto_delete` explicitly for Terraform-managed PVCs.
- On VM deletion, the provider annotates PVCs selected for removal before foreground-deleting the VM.
- Existing or valuable PVCs should use `auto_delete = false`.
- Never infer deletion intent from a disk name.

## Networking

```hcl
network_interface {
  name           = "nic-1"
  model          = "virtio"
  type           = "bridge"
  network_name   = harvester_network.workload.id
  wait_for_lease = true
}
```

Rules:

- Empty `network_name`: management pod network; inferred type is `masquerade`.
- Non-empty `network_name`: Multus/Harvester network; inferred type is `bridge`.
- Explicit types accepted: `bridge`, `masquerade`.
- Models accepted: `virtio`, `e1000`, `e1000e`, `ne2k_pco`, `pcnet`, `rtl8139`.
- `mac_address` may be omitted and is then computed.
- `ip_address` and `interface_name` are computed from VMI status.
- `wait_for_lease = true` keeps create/update from becoming `Ready` until an IP is reported. A secondary/VLAN NIC generally requires qemu-guest-agent; without it Terraform may time out even while the VM is running.

## Cloud-init and SSH keys

Cloud-init type is `noCloud` by default; `configDrive` is also supported. Config-drive uses a SATA CD-ROM; no-cloud uses a virtio disk. These are the literal enum strings enforced by the provider's ValidateFunc (verified against the schema of the installed provider version); do not use the kebab-case spellings (`no-cloud`/`config-drive`) sometimes seen in unrelated tooling.

```hcl
cloudinit {
  type                  = "noCloud"
  user_data_secret_name = harvester_cloudinit_secret.vm_config.name
}
```

For each payload choose one of:

- `user_data`, `user_data_base64`, or `user_data_secret_name`
- `network_data`, `network_data_base64`, or `network_data_secret_name`

SSH injection behavior:

- `ssh_keys` references Harvester KeyPairs, normally as namespace/name IDs.
- The provider injects keys only when user data is not base64 and not Secret-backed, and only when inline user data lacks `ssh_authorized_keys`.
- `tags = { ssh-user = "ubuntu" }` similarly injects `user:` only when user data is not base64/Secret-backed and inline user data lacks `user`.
- If external/base64 cloud-init is used, the provider validates that every `ssh_keys` public key already appears under `ssh_authorized_keys`; otherwise creation/update fails.
- Treat inline cloud-init and Terraform state as potentially sensitive. Prefer Secret-backed data for credentials.

## Compute, boot, and placement

- Defaults: `cpu = 1`, `memory = "1Gi"`, `run_strategy = "RerunOnFailure"`.
- Valid run strategies: `Always`, `Manual`, `Halted`, `RerunOnFailure`.
- Do not rely on deprecated `start`; map true to `RerunOnFailure` and false to `Halted`.
- `requests` accepts Kubernetes quantities. If omitted, Harvester's overcommit webhook manages requests.
- `secure_boot = true` requires `efi = true`; provider also enables SMM.
- `isolate_emulator_thread = true` requires CPU manager support and `cpu_pinning = true`; it allocates an additional dedicated CPU.
- `node_selector` directly controls pod scheduling; verify target node labels and required hardware.
- `host_device` needs both a unique VM-local name and the cluster resource/device name.
- Add `tpm {}` only when TPM is required.

## Lifecycle behavior

- Default create/read/update timeout: 2 minutes; delete: 5 minutes.
- `restart_after_update` triggers KubeVirt's VM restart subresource only for `Always` and `RerunOnFailure`.
- During restart, the provider records the old VMI UID and waits for a replacement VMI before declaring readiness.
- `Halted` waits for state `Off`; `Always` and `RerunOnFailure` wait for `Ready`.
- `Manual` does not enter the provider's state waiter; manage its start/stop lifecycle deliberately.
- `create_initial_snapshot = true` creates a `VirtualMachineBackup` named `<vm-name>-initial` with type `snapshot` after readiness. Snapshot failure returns a warning; the VM remains created. It does not wait for snapshot completion.

## Lookup and import

```hcl
data "harvester_virtualmachine" "existing" {
  name      = "ubuntu-01"
  namespace = "default"
}
```

```sh
terraform import harvester_virtualmachine.ubuntu default/ubuntu-01
```

After import, run `terraform plan` and review disk `auto_delete`, inferred/computed fields, cloud-init, and network values before applying.

## API mental model

The primary object is:

```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: <name>
  namespace: <namespace>
spec:
  runStrategy: RerunOnFailure
  template:
    spec:
      domain: {}
      networks: []
      volumes: []
```

Runtime state and guest interfaces come from the same-named `VirtualMachineInstance`. Restart uses KubeVirt's `virtualmachines/restart` subresource. Initial snapshot uses Harvester's `harvesterhci.io/v1beta1` `VirtualMachineBackup`.

Read `references/api.md` when translating Terraform to API objects, diagnosing states/conditions, or explaining PVC/network/cloud-init mappings.

## Troubleshooting order

1. Inspect both VM and VMI; a VM may exist while the VMI is absent (`Off`).
2. Check `run_strategy`; `Halted` intentionally produces no running VMI.
3. Inspect VMI phase, conditions, events, and pod scheduling.
4. For a stuck `Running` state, check every `wait_for_lease` NIC and qemu-guest-agent.
5. Validate image state and image namespace/name.
6. Inspect generated PVCs, storage class, access/volume mode, capacity, and `auto_delete` intent.
7. Validate network name, NAD/Multus availability, VLAN configuration, and interface model.
8. Check cloud-init syntax, Secret keys, and referenced SSH KeyPairs.
9. For Secure Boot, confirm EFI; for CPU pinning/devices, confirm schedulable nodes expose required resources.
10. Increase timeouts only after identifying a legitimately slow asynchronous operation.

Useful commands:

```sh
kubectl -n <namespace> get vm <name> -o yaml
kubectl -n <namespace> get vmi <name> -o yaml
kubectl -n <namespace> describe vmi <name>
kubectl -n <namespace> get pvc
```

## Safety and output quality

- Never apply, restart, stop, or destroy a VM unless explicitly requested.
- Never expose kubeconfig, cloud-init credentials, private keys, or Secret data.
- Preserve existing disks and `auto_delete` settings during updates/import reconciliation.
- Avoid changing boot firmware, disk buses, MAC addresses, or device assignments without explaining downtime and guest impact.
- State provider-version assumptions when generated behavior depends on current source rather than stable documentation.
