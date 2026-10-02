# protected-volume

## Purpose and scope

Creates independently managed, empty Harvester data PVCs keyed by exact volume
name. Adds protection labels, Terraform destruction guards, and frozen size
updates. Does not attach volumes, clone images, create StorageClasses, install
admission protection, or provide backups.

## Requirements and providers

| Dependency | Declared constraint / requirement |
| --- | --- |
| Terraform | `>= 1.3`; mocked tests require 1.7+. |
| `harvester/harvester` | `= 1.9.0` |

Configure the provider in the caller. The namespace and all referenced
StorageClasses must exist. The module looks up the default class and every
per-volume override. Provider volume read/import also lists KubeVirt VMs in the
namespace, requiring `list` on `virtualmachines.kubevirt.io`.

For protection beyond Terraform configuration, deploy `../volume-protection-policy`
once per cluster from separately controlled state before creating protected PVCs.
This module does not install or verify that policy. Restrict policy mutation and
PVC deletion through independently managed RBAC and audited emergency access.

## Default context

Volumes default to namespace `default`, `Block` volume mode, `ReadWriteOnce`
access, and a `10m` delete timeout. `Block` with `ReadWriteOnce` suits a raw
disk attached to one VM at a time; use `Filesystem` when a consumer needs a
mounted filesystem, and change access mode only with a backend and application
that support the sharing semantics. There is no default StorageClass: it is
required so a cluster-side default change cannot silently relocate volumes.

Volumes are created empty and are not attached, formatted, or backed up here.
Size is required per volume and frozen afterwards; destruction is blocked while
configured. Treat every volume as long-lived, and plan expansion, migration, or
decommissioning through the documented out-of-band workflows below.

## Usage

Caller configuration snippet, **not a standalone root module**: declare and supply
all referenced variables and configure the provider separately. The source path
assumes the caller is at the **repository root**; adjust it elsewhere.

This example chooses the PVC name `application-data` at `100Gi` and keeps the
default namespace and modes. Keys are exact PVC names, not logical aliases.

```hcl
module "data" {
  source = "./modules/protected-volume"

  storage_class_name = var.storage_class_name

  volumes = {
    "application-data" = { size = "100Gi" }
  }
}
```

To attach that volume to the singleton VM utility, extend the caller as below.
The VM must be in the volume's namespace; `data` is the chosen device key.

```hcl
module "machine" {
  source = "./modules/virtual-machine"

  name       = "utility-vm"
  root_image = var.root_image_id

  persistent_disks = {
    data = { existing_volume_name = module.data.names["application-data"] }
  }
}
```

## Inputs

| Name | Type | Required / default | Meaning |
| --- | --- | --- | --- |
| `namespace` | `string` | `"default"` | Existing namespace; DNS-1123 label, 1–63 characters. |
| `storage_class_name` | `string` | Required | Explicit default StorageClass; DNS-1123 subdomain, at most 253 characters. Required even when every volume overrides it. |
| `volume_mode` | `string` | `"Block"` | Default `Block` or `Filesystem`. |
| `access_mode` | `string` | `"ReadWriteOnce"` | Default `ReadWriteOnce`, `ReadOnlyMany`, or `ReadWriteMany`. |
| `labels` | `map(string)` | `{}` | Common labels; override per-volume labels but not module-managed labels. |
| `tags` | `map(string)` | `{}` | Common Harvester tags; per-volume tags take precedence. |
| `delete_timeout` | `string` | `"10m"` | Provider deletion timeout; does not bypass lifecycle/admission guards or set a timeout on external deletion tools. |
| `volumes` | `map(object)` | Required, non-empty | Exact PVC names mapped to attributes below. Keys must be DNS-1123 subdomains with labels of 1–63 characters, at most 253 total. |

Each `volumes` value supports:

| Attribute | Type | Required / default | Meaning |
| --- | --- | --- | --- |
| `size` | `string` | Required | Initial supported Kubernetes quantity, such as `100Gi`; subsequent changes are ignored for mutation. |
| `storage_class_name` | `string` | `null` | Override default class; same DNS validation. |
| `volume_mode` | `string` | `null` | Override default mode; `Block` or `Filesystem`. |
| `access_mode` | `string` | `null` | Override default access mode; same three allowed values. |
| `description` | `string` | `null` | Volume description. |
| `labels` | `map(string)` | `{}` | Per-volume labels, lower precedence than common/managed labels. |
| `tags` | `map(string)` | `{}` | Per-volume Harvester tags, overriding common tags. |

Managed labels are `app.kubernetes.io/managed-by = terraform`,
`app.kubernetes.io/instance = <PVC name>`,
`platform.harvester.io/protected = true`, and
`platform.harvester.io/protection-v1 = enabled`. Callers cannot override them.

## Outputs

All outputs are maps keyed by PVC name.

| Output | Meaning |
| --- | --- |
| `names` | PVC names; pass one to `persistent_disks.<device>.existing_volume_name`. |
| `ids` | Resource IDs (`namespace/name`). |
| `storage_class_names` | Effective StorageClasses. |
| `volume_modes` | Effective volume modes. |
| `access_modes` | Effective access modes. |
| `declared_sizes` | Current input sizes, not live capacity readings. |
| `observed_sizes` | Last provider-observed sizes; not proof of backend/guest resize completion. |
| `phases` | Observed PVC phases; apply can finish before `Bound`. |

## Behavior and limitations / lifecycle

- `prevent_destroy = true` blocks planned destruction/replacement while its
  resource configuration remains, including key removal/rename and `-replace`.
  It is **not absolute protection**: removing the module/resource configuration
  removes the guard, and direct API deletion is outside Terraform. Admission
  protection also depends on preserving its policy/binding and restricting bypass.
- `ignore_changes = [size]` freezes updates, including both growth and shrinkage.
  Declared and observed sizes can differ. For expansion, verify StorageClass
  expansion support, backups, capacity, and approval; resize out of band, verify
  PVC/backend and guest filesystem completion, then align the declared size.
- Do not change StorageClass, volume mode, or access mode on existing PVCs.
  Provider 1.9.0 may plan an in-place update that Kubernetes rejects. Create a
  new protected volume, stop writes, copy/restore data, migrate attachments, and
  retain the old volume through the rollback window before decommissioning.
- `ReadWriteMany` does not make an ordinary ext4/xfs guest filesystem safe for
  simultaneous writers. Shared access needs a compatible backend and application
  design; `ReadWriteOnce` is not a substitute for consumer checks.
- Provider 1.9.0 does not wait for `Bound` on create or resize completion on update.
  Its `attached_vm` and derived `state` are unreliable and intentionally not
  exposed. Check actual VM/VMI, Pod, and VolumeAttachment references, including
  stopped VM templates, before deletion.
- Protect state with access controls, encryption, locking, and versioning. Use CI
  checks for deletion/replacement, configuration removal, size decreases, and
  immutable-field changes; ignored sizes may require configuration review beyond
  resource-change JSON. Maintain backups and tested restore procedures.

### Decommissioning a volume

There is no `allow_destroy` switch. First verify all consumers are gone, obtain
approval, and verify a backup/restore procedure. Under a controlled change window,
relinquish Terraform ownership **without deletion** and remove matching caller
configuration before any further apply. For a single `for_each` instance, use an
approved `terraform state rm` on its exact address; this forgets the PVC, not its
data. Confirm the PVC still exists and Terraform no longer owns it. A supported
resource-level `removed` block with `destroy = false` can cover an entire
collection, not a single keyed instance; it requires Terraform 1.7+.

Only then authenticate as the audited break-glass Kubernetes identity, remove
`platform.harvester.io/protected`, and delete the PVC after rechecking approvals
and consumers. Impersonation, if used, requires separately authorized RBAC; the
policy does not grant it. Preserve audit evidence. Never reintroduce an unprotected
resource solely to delete it, or leave configuration that would recreate it.

### Import

Declare the exact existing name and matching class/modes, then import its
`namespace/name` ID into `module.data.harvester_volume.this["<PVC name>"]` using
the actual caller module address. Review the plan before applying labels and
metadata; do not accept replacement or immutable-field changes. Size remains
ignored after import. Verify protection labels and admission enforcement explicitly.

## Testing

Run from `modules/protected-volume` with Terraform 1.7+:

```sh
terraform init -backend=false
terraform validate
terraform test
```

Tests use a mocked provider to check inputs, labels, overrides, and outputs. They
do not prove destruction protection against existing state, live PVC readiness,
resize behavior, or admission enforcement. Provider installation requires registry
access or a configured mirror/cache.
