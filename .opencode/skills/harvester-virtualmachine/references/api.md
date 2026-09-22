# Harvester virtual machine API reference

Summarizes behavior investigated from the current `terraform-provider-harvester` source. Re-check the installed provider version before relying on implementation-specific details.

## Terraform-to-API mapping

| Terraform field | Underlying API location | Notes |
|---|---|---|
| `name`/`namespace` | KubeVirt `VirtualMachine.metadata` | Terraform ID is `namespace/name` |
| `cpu` | `spec.template.spec.domain.cpu.cores` | Default `1` |
| `cpu_model` | `spec.template.spec.domain.cpu.model` | Optional |
| `memory` | `spec.template.spec.domain.resources.limits.memory` | Default `1Gi` |
| `requests.cpu`/`requests.memory` | `spec.template.spec.domain.resources.requests` | Parsed as Kubernetes quantities |
| `cpu_pinning` | `spec.template.spec.domain.cpu.dedicatedCpuPlacement` | Requires CPU manager node support |
| `isolate_emulator_thread` | `spec.template.spec.domain.cpu.isolateEmulatorThread` | Requires `cpu_pinning` |
| `efi` | `spec.template.spec.domain.firmware.bootloader.efi` | Preserves existing UUID/Serial on update |
| `secure_boot` | same firmware block + `features.smm.enabled` | Requires `efi = true` |
| `machine_type` | `spec.template.spec.domain.machine.type` | e.g. `q35` |
| `hostname` | `spec.template.spec.hostname` | |
| `reserved_memory` | annotation `harvesterhci.io/reservedMemory` | Removed when empty |
| `node_selector` | `spec.template.spec.nodeSelector` | Fully replaced on each apply |
| `host_device` | `spec.template.spec.domain.devices.hostDevices` (via builder `AddHostDevice`) | Needs name + device resource name |
| `run_strategy` | `spec.runStrategy` | `Always`, `Manual`, `Halted`, `RerunOnFailure` |
| `ssh_keys` | annotation carrying namespaced KeyPair names + cloud-init injection | See SSH key section |
| `tags` (`ssh-user`) | VM label + cloud-init `user:` injection | See SSH key section |
| `network_interface[*]` | `spec.template.spec.domain.devices.interfaces` + `spec.template.spec.networks` | See network section |
| `disk[*]` | `spec.template.spec.domain.devices.disks` + `spec.template.spec.volumes` (+ PVC templates) | See disk section |
| `cloudinit` | disk named `cloudinitdisk` + matching volume | Single block, `noCloud` or `configDrive` |
| `input[*]` | `spec.template.spec.domain.devices.inputs` | tablet/keyboard style input devices |
| `tpm` | `spec.template.spec.domain.devices.tpm` | Presence-only block |
| `node_name` | `VirtualMachineInstance.status.nodeName` | Computed, requires running VMI |
| `state`, `message` | Derived from VM run strategy + VMI phase | See state section |

## Provider builder

The provider constructs objects with Harvester's own `pkg/builder.VMBuilder`, not raw KubeVirt structs. Key helper calls seen in the constructor:

- `vmBuilder.CPU`, `.Memory`, `.MachineType`, `.HostName`, `.RunStrategy`, `.Run` (deprecated `start` path)
- `vmBuilder.NetworkInterface(name, model, mac, type, networkName)`, `.WaitForLease(name)`, `.SetNetworkInterfaceBootOrder(name, order)`
- `vmBuilder.Disk(name, bus, isCDRom, bootOrder)`, `.DiskCacheMode(name, mode)`, `.PVCVolume`, `.ExistingPVCVolume`, `.ContainerDiskVolume`
- `vmBuilder.CloudInit(diskName, cloudInitSource)`
- `vmBuilder.SSHKey(namespacedName)`
- `vmBuilder.Input(name, type, bus)`
- `vmBuilder.TPM()`
- `vmBuilder.AddHostDevice(name, deviceName, "")`

Because Harvester supplies this builder, low-level KubeVirt object shape may shift between Harvester releases; treat exact struct fields as an implementation detail and prefer Terraform-level fields plus `kubectl get vm -o yaml` for verification.

## Create/Read/Update/Delete flow

### Create

1. Build the VM object with the builder (namespace, name, eviction strategy `LiveMigrate`, default pod anti-affinity).
2. Apply schema-driven processors (cpu, memory, EFI, disks, network interfaces, cloud-init, ssh keys, etc).
3. `Validate()` cross-checks `ssh_keys` against literal cloud-init `ssh_authorized_keys` content when cloud-init is not base64/Secret-backed.
4. Create the KubeVirt `VirtualMachine`.
5. Re-set locally managed fields (`restart_after_update`, `create_initial_snapshot`) back into Terraform state (they are not server-side fields).
6. Wait for state based on `run_strategy` (see state table).
7. If `create_initial_snapshot = true`, create a `VirtualMachineBackup` (`type: snapshot`) named `<vm-name>-initial`. Failure here is a non-fatal warning; VM creation still succeeds.

### Update

1. Get the current VM.
2. The `Updater` constructor clears networks, interfaces, disks, inputs, volumes, TPM, and the `AnnotationVolumeClaimTemplates` annotation before reapplying from Terraform config. Effectively, hardware topology is fully rebuilt from current HCL rather than diffed.
3. Re-run the same schema-driven processors as create.
4. Update the KubeVirt `VirtualMachine`.
5. Determine `RunStrategy()`; if `IsNeedRestart` (restart_after_update true, and run strategy is `Always`/`RerunOnFailure`), call the KubeVirt `virtualmachines/{name}/restart` subresource. The old VMI UID is captured first so the waiter can detect the new instance.
6. Wait for state, matching the pre-restart UID logic so Terraform does not treat the pre-restart instance as already ready.

### Read

1. Split Terraform ID into namespace/name.
2. GET the `VirtualMachine`; 404 clears state.
3. GET the matching `VirtualMachineInstance`; 404 is tolerated (VM may be stopped).
4. Import spec/status into Terraform state through `VMImporter`.

### Delete

1. GET the VM.
2. Compute PVCs to remove: any Terraform-tracked disk with `auto_delete=false` is excluded; all other PVC-backed volumes (including ones no longer tracked in the current disk blocks) are included.
3. Patch the VM's `harvesterhci.io/removedPVCs` annotation with the comma-joined list before deleting, so Harvester's own controller can garbage-collect matching PVCs.
4. Delete the VM with `PropagationPolicy=Foreground`.
5. Poll until state is `Removed`.

## Disk and volume construction rules

Disk bus default resolution when `bus` is empty:

1. CD-ROM (`type = "cd-rom"`) → `sata`
2. Hot-plug disk (`hot_plug = true`) → `scsi`
3. Otherwise → `virtio`

Volume source resolution, in priority order, per disk block:

1. `existing_volume_name` set → attach existing PVC (`ExistingPVCVolume`), honoring `hot_plug`.
2. `container_image_name` set → KubeVirt container disk (`ContainerDiskVolume`, default pull policy).
3. CD-ROM with empty `image` → no volume is prepared (empty virtual CD-ROM tray).
4. Otherwise → create a new PVC (`PVCVolume`) with:
   - default `VolumeMode = Block`, `AccessMode = ReadWriteMany` unless overridden
   - `image` (namespace/name) resolves the Harvester `VirtualMachineImage`; the PVC's storage class is forced to the image's own `status.storageClassName`. Supplying a conflicting `storage_class_name` on the disk is a validation error: "the storage_class_name of an image can only be defined during image creation."
   - when no `image` and empty `storage_class_name`, the provider looks up the storage class annotated as the cluster default.
   - `auto_delete = true` sets annotation `terraform-provider-harvester-auto-delete: "true"` on the PVC template.
   - `size` must be a parsable Kubernetes quantity; empty defaults to the Harvester builder default disk size.

## Network interface construction rules

- Empty `network_name` → management/pod network; inferred `type = masquerade`.
- Non-empty `network_name` → inferred `type = bridge` (Multus network attachment).
- `wait_for_lease = true` registers the interface name in an annotation so the read/import path and state waiter know to require an IP before declaring `Ready`.
- `boot_order` is only set on the interface when non-zero.
- On read, `ip_address`/`interface_name` are populated by matching VMI `status.interfaces` for the same interface name, filtered to drop link-local IPv4/IPv6 addresses, then choosing the numerically smallest remaining IP.

## Cloud-init construction rules

- Cloud-init disk is always named `cloudinitdisk` internally (`builder.CloudInitDiskName`).
- `type = "configDrive"` uses a SATA CD-ROM disk; default `noCloud` uses a virtio disk. The provider validates these exact camelCase strings; kebab-case values are rejected at plan/apply time.
- SSH/user injection into literal `user_data` happens only when both `user_data_base64` and `user_data_secret_name` are empty:
  - If a `ssh-user` tag exists and inline `user_data` has no `user:` line, the provider appends/creates one.
  - The provider fetches each `ssh_keys` KeyPair's public key and appends them under a generated `ssh_authorized_keys:` section, unless inline `user_data` already defines that key.
- When cloud-init is base64 or Secret-backed, the provider does not inject; instead `Validate()` decodes/looks up the actual payload and requires every `ssh_keys` public key to already be present under `ssh_authorized_keys`, otherwise it fails with a listing of missing key pairs.

## SSH key identity handling

- `ssh_keys` entries are rebuilt/normalized to `namespace/name` relative to the VM's own namespace.
- Import reverses this by reading the VM template annotation storing configured SSH names as JSON and rebuilding namespaced identifiers.

## State derivation

Terraform `state` combines VM `run_strategy` (via KubeVirt's own `RunStrategy()` helper) with the VMI phase:

| Condition | State |
|---|---|
| No VMI object | `Off` |
| VMI phase Pending/Scheduling/Scheduled | `Starting` |
| VMI phase Running, and VMI UID equals the pre-restart UID captured before an update | `Running` (still old instance; not yet considered ready) |
| VMI phase Running, any `wait_for_lease` interface lacking a resolved IP | `Running` (still waiting) |
| VMI phase Running, all `wait_for_lease` interfaces resolved (or none configured) | `Ready` |
| VMI phase Succeeded | `Stopping` |
| VMI phase Failed | `Failed` |
| Any other/unrecognized phase | `Unknown` |

Provider wait targets by run strategy:

| `run_strategy` | Wait target | Pending states tolerated while waiting |
|---|---|---|
| `Halted` | `Off` | `Starting`, `Stopping`, `Running`, `Failed`, `Unknown`, `Ready` |
| `Always` / `RerunOnFailure` | `Ready` | `Starting`, `Stopping`, `Running`, `Failed`, `Unknown`, `Off` |
| `Manual` | none (returns immediately) | not applicable |

Delete waits through `Ready`/`Failed`/`Unknown`/`Running`/`Starting`/`Stopping`/`Off` until the VM object itself is `Removed` (404).

## Default timeouts

| Operation | Provider default |
|---|---:|
| create | 2 minutes |
| read | 2 minutes |
| update | 2 minutes |
| delete | 5 minutes |
| default | 2 minutes |

State-wait polling uses a 10-second delay and 3-second minimum poll interval.

## Initial snapshot

```yaml
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineBackup
metadata:
  name: <vm-name>-initial
  namespace: <namespace>
spec:
  type: snapshot
  source:
    apiGroup: kubevirt.io
    kind: VirtualMachine
    name: <vm-name>
```

This is fire-and-forget from the provider's perspective: it does not poll the backup to completion. A failure downgrades to a Terraform warning diagnostic rather than failing the apply.

## Import

```sh
terraform import harvester_virtualmachine.foo <Namespace>/<Name>
```

After import, carefully review computed/inferred values, especially disk `auto_delete` (defaults to Computed, not necessarily `true`), storage/access/volume modes, and any pre-existing PVCs that may not map back onto `image`/`existing_volume_name` cleanly.

## Data source behavior

`harvester_virtualmachine` data source only supports lookup by `name` + `namespace` (no display-name-style secondary lookup, unlike the image data source). It shares the resource's full schema in read-only form.

## Investigated sources

- Terraform Registry resource supplied by the user.
- `terraform-provider-harvester/docs/resources/virtualmachine.md`
- `internal/provider/virtualmachine/schema_virtualmachine.go`
- `internal/provider/virtualmachine/schema_virtualmachine_disk.go`
- `internal/provider/virtualmachine/schema_virtualmachine_network_interface.go`
- `internal/provider/virtualmachine/schema_virtualmachine_cloudinit.go`
- `internal/provider/virtualmachine/resource_virtualmachine.go`
- `internal/provider/virtualmachine/resource_virtualmachine_constructor.go`
- `internal/provider/virtualmachine/resource_virtualmachine_validator.go`
- `pkg/importer/resource_virtualmachine_importer.go`
- `pkg/constants/constants_virtualmachine.go`
