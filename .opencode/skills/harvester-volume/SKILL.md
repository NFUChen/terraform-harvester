---
name: harvester-volume
description: Harvester Terraform persistent volume management using harvester_volume, Kubernetes PVCs, Longhorn storage classes, image-backed volumes, expansion, import, VM attachment, retention, prevent_destroy, and volume troubleshooting. Use whenever a user asks to create, inspect, resize, import, protect, attach, detach, migrate, or design Terraform modules for Harvester data disks or PVCs, even if they only mention datadisk, persistent disk, existing_volume_name, storage class, access mode, volume mode, Bound/Pending PVC, or storage deletion safety.
compatibility: Requires Terraform with harvester/harvester provider 1.9.0 and Harvester kubeconfig access.
metadata:
  domain: harvester
  resource: harvester_volume
---

# Harvester Volume

Use this skill to manage Harvester persistent volumes safely. A `harvester_volume` is a namespaced Kubernetes `PersistentVolumeClaim` (PVC), not a custom Harvester CRD. Treat data ownership and deletion safety as first-class concerns.

## First determine intent

Collect only missing information:

1. Operation: create, inspect, import, expand, attach, detach, protect, migrate, or troubleshoot.
2. Identity: Terraform label, Kubernetes `name`, and `namespace`.
3. Source: empty PVC or clone from a Harvester image.
4. Capacity: requested size; expansion only, never shrink.
5. Storage policy: storage class, volume mode, and access mode.
6. Ownership: ephemeral with a VM, or persistent and independently managed.
7. Attachment: target VM and disk name; one PVC per VM unless shared storage/filesystem semantics are explicitly verified.
8. Protection: `prevent_destroy`, backup/snapshot, remote state, and approval policy.

Do not invent storage classes, image IDs, namespaces, volume names, or deletion intent.

## Typical single-VM data volume

The provider defaults to `Block` + `ReadWriteMany`, but those defaults are not universally safe. For an ordinary volume owned by one VM, prefer single-writer semantics unless the storage backend and guest filesystem/application have been explicitly designed and tested for shared access:

```hcl
resource "harvester_volume" "data" {
  name      = "web-01-data"
  namespace = "default"

  size        = "100Gi"
  volume_mode = "Block"
  access_mode = "ReadWriteOnce"

  labels = {
    "app.kubernetes.io/managed-by" = "terraform"
    "app.kubernetes.io/instance"   = "web-01"
    "app.kubernetes.io/component"  = "data"
  }

  lifecycle {
    prevent_destroy = true
  }

  timeouts {
    delete = "10m"
  }
}
```

Attach it to a VM through `existing_volume_name` and ensure VM-side `auto_delete = false`:

```hcl
disk {
  name                 = "data"
  type                 = "disk"
  bus                  = "virtio"
  existing_volume_name = harvester_volume.data.name
  auto_delete          = false
}
```

Keep important volumes outside the VM module so VM replacement, scale-down, and image changes cannot destroy data ownership.

## Source modes

### Empty volume

```hcl
resource "harvester_volume" "data" {
  name               = "web-01-data"
  namespace          = "default"
  size               = "100Gi"
  storage_class_name = harvester_storageclass.data.name
  volume_mode        = "Block"
  access_mode        = "ReadWriteMany"
}
```

When `storage_class_name` is omitted, Kubernetes defaulting may select the cluster default storage class. Prefer an explicit storage class for production so a cluster-default change cannot alter future volume placement.

### Image-backed volume

```hcl
resource "harvester_volume" "root_clone" {
  name      = "web-01-root-clone"
  namespace = "default"

  size  = "40Gi"
  image = harvester_image.ubuntu.id
}
```

The provider converts `image` to the Harvester image annotation and derives an image-specific storage class. Do not set `storage_class_name` together with `image`; the provider may reject a mismatch and `storage_class_name` is Optional+Computed, which can retain stale state across updates.

Use image-backed volumes for intentional clones. For ordinary persistent application data, use an empty volume and explicit storage class.

## Provider 1.9.0 defaults

| Field | Provider default |
|---|---|
| `namespace` | `default` |
| `size` | `1Gi` |
| `volume_mode` | `Block` |
| `access_mode` | `ReadWriteMany` |
| create/read/update schema timeout | 2 minutes |
| delete timeout | 5 minutes |

Do not treat the provider defaults as architecture recommendations. Validate that the selected CSI driver, storage class, attachment pattern, and guest filesystem support the chosen access and volume modes. In 1.9.0, create/read/update do not use their timeout values for readiness polling; increasing them does not make Terraform wait for binding, image population, or resize completion. Delete is the meaningful polling timeout.

## Mutable and immutable behavior

Although the provider schema does not mark these fields ForceNew, Kubernetes PVC rules still apply:

- `storage_class_name`: immutable after creation.
- `volume_mode`: immutable after creation.
- `access_mode`: commonly immutable or constrained; treat as replacement-only.
- `image`: changes storage initialization/storage class semantics; treat as replacement-only.
- `size`: may expand only if the StorageClass supports expansion; cannot shrink.

Never trust an in-place Terraform plan for immutable PVC fields. A safe wrapper module should force replacement or reject the change before apply. Replacement destroys the PVC, so protected persistent data should normally reject immutable changes rather than automatically replace.

## Resize workflow

1. Confirm the StorageClass has `allowVolumeExpansion: true`.
2. Confirm the backend supports online/offline expansion for this volume mode.
3. Increase `size`; never decrease it.
4. Review the plan and apply.
5. Inspect PVC conditions and capacity after apply.
6. For filesystem volumes, verify guest/filesystem expansion requirements.

The provider update path performs a normal PVC Update and immediately reads the object; it does not wait for requested capacity to become effective.

## Create readiness caveat

Provider create returns immediately after the PVC API create succeeds. It does not wait for:

- PVC phase `Bound`;
- Longhorn volume readiness;
- image population completion;
- requested capacity becoming available.

Do not assume successful `terraform apply` means the volume is ready to attach or mount. Check:

```sh
kubectl -n <namespace> get pvc <name> -o yaml
```

For automation, add an external readiness gate or let the consuming VM/controller wait for the claim.

## Deletion behavior

Provider delete issues a direct Kubernetes PVC delete and waits for the PVC object to disappear. It does not:

- check `attached_vm` first;
- detach the volume;
- create a snapshot/backup;
- preserve data;
- protect against another Terraform state or kubectl deletion.

Deletion can succeed even while a stopped VM template still references the PVC. PVC protection may delay deletion while an active Pod uses the claim, but this is not a reliable Harvester VM attachment lock. Finalizers or active consumers can also make deletion wait until timeout. For important data, use `prevent_destroy`, separate state, RBAC, backups, and CI plan approval.

## Data source and import

Lookup:

```hcl
data "harvester_volume" "data" {
  name      = "web-01-data"
  namespace = "default"
}
```

Import:

```sh
terraform import harvester_volume.data default/web-01-data
```

After import, inspect `terraform plan` carefully. Match size, storage class, volume/access modes, image annotation, labels, and tags before apply. Immutable-field drift cannot be reconciled safely with a normal update.

## Do not trust `attached_vm` in provider 1.9.0

The 1.9.0 importer has an attachment detection bug: while iterating VMs, it checks only whether a VM has any PVC volume and does not compare that claim name with the volume being read. It can therefore mark unrelated volumes as `In-use`. The reported `attached_vm` value is also built from the volume namespace/name rather than the actual VM name.

For deletion safety, inspect all plausible consumers rather than only VM templates:

```sh
kubectl -n <namespace> get vm,vmi,pod -o yaml
kubectl -n <namespace> get pvc <name> -o jsonpath='{.spec.volumeName}'
kubectl get volumeattachment -o yaml
```

Check VM and VMI volume claims, Pod PVC references (including virt-launcher and non-VM Pods), then map the PVC's bound PV name to CSI `VolumeAttachment` objects. A `VolumeAttachment` references a PV, not a PVC directly. Do not build automation that authorizes deletion based on provider `state` or `attached_vm` until this behavior is fixed and verified in the selected release.

Provider 1.9.0 volume read/import also lists all KubeVirt VMs in the PVC namespace. Credentials therefore need permission to list VMs in addition to PVC CRUD/read permissions; otherwise create refresh, data-source reads, and import can fail even when attachment information is not needed.

## Troubleshooting order

1. Inspect the PVC phase, conditions, events, storage class, requested size, access mode, and volume mode.
2. Inspect the StorageClass provisioner, parameters, expansion capability, and binding mode.
3. For image-backed volumes, verify image ID/namespace, image readiness, and derived storage class.
4. For `Pending`, inspect scheduler/topology constraints and Longhorn replica capacity.
5. For resize, verify requested vs actual capacity and PVC conditions.
6. For delete timeout, inspect `metadata.finalizers`, VM references, VolumeAttachment objects, and backend state.
7. Do not rely on provider `attached_vm`; verify VM specs directly.

## Safety rules

- Keep persistent data volumes as independent Terraform resources.
- Add `prevent_destroy` for protected data.
- Never auto-delete an externally managed PVC from a VM resource.
- Never shrink a PVC.
- Treat image/storage class/volume mode/access mode changes as destructive migration, not ordinary update.
- Prefer one PVC per VM unless both storage and guest filesystem explicitly support sharing.
- Use backups/snapshots before migration or replacement.
- Review saved plans and block PVC deletion in CI without explicit approval.

Read `references/api.md` when reasoning about provider internals, state fields, update limitations, or wrapper-module design.
