# protected-volume

Data-safety-first wrapper around `harvester_volume` for the platform team.
Every managed PVC has `lifecycle.prevent_destroy = true`; normal Terraform
operations cannot delete it.

## Guarantees

While the module remains in configuration, it blocks PVC deletion caused by:

- `terraform destroy`;
- removing a key from `volumes`;
- renaming a `volumes` key;
- `terraform apply -replace=...`;
- immutable-field replacement planned by Terraform.

This protection was verified with a real Terraform state and
`terraform plan -destroy`: Terraform returns `Instance cannot be destroyed`.

Terraform stores `prevent_destroy` in configuration, not state. Removing the
entire module block also removes that lifecycle rule, so a child module alone
cannot guarantee protection against module removal. Production use therefore
requires the companion `../volume-protection-policy` module, which installs a
cluster-level admission policy that keeps denying PVC deletion even when this
Terraform configuration is gone.

That admission policy is the real enforcement boundary, and it must be owned
by a different identity than the one running day-to-day volume changes. A
single identity that can edit every state and every module can always take
the whole protection stack apart; no amount of additional Terraform closes
that loop. See `../volume-protection-policy/README.md` for the required RBAC
split, audit alerting, and separation-of-duties model.

The module does not use images. Image clones have different replacement
semantics and belong in a separate future module.

## Required cluster protection

Install the companion admission policy once per cluster from a separately
protected platform/foundation state before creating volumes:

```hcl
provider "kubernetes" {
  config_path = var.kubeconfig
}

module "volume_protection_policy" {
  source = "./modules/volume-protection-policy"

  break_glass_usernames = [
    "platform-break-glass",
  ]
}
```

The policy denies both deletion of protected PVCs and removal of their
protection label. It is fail-closed and only exact audited break-glass
usernames can bypass it. The normal Terraform service account must never be a
break-glass identity.

## Quick start

```hcl
module "web_data" {
  source = "./modules/protected-volume"

  namespace          = "default"
  storage_class_name = "harvester-longhorn"

  volumes = {
    "web-01-data" = { size = "100Gi" }
    "web-02-data" = { size = "100Gi" }
    "web-03-data" = { size = "100Gi" }
  }
}
```

The map key is the exact PVC name. Keep it stable for the lifetime of the
data. Renaming a key means a different Kubernetes object, not a rename.

## Safe defaults and overrides

Module defaults:

```hcl
volume_mode = "Block"
access_mode = "ReadWriteOnce"
```

A global StorageClass is required. This avoids silently placing new volumes
on a different backend after the cluster default StorageClass changes.

Each volume may override common policy when the platform design requires it:

```hcl
module "data" {
  source = "./modules/protected-volume"

  storage_class_name = "harvester-longhorn"
  volume_mode        = "Block"
  access_mode        = "ReadWriteOnce"

  volumes = {
    "database-data" = {
      size               = "500Gi"
      storage_class_name = "longhorn-ssd"
      labels = {
        workload = "database"
      }
    }

    "shared-files" = {
      size        = "1Ti"
      volume_mode = "Filesystem"
      access_mode = "ReadWriteMany"
    }
  }
}
```

Use `ReadWriteMany` only when the CSI backend and guest filesystem/application
are explicitly designed and tested for shared access. A normal ext4/xfs block
filesystem must not be mounted by multiple VMs concurrently.

The module reads every distinct StorageClass at plan time. A misspelled or
missing class fails before Kubernetes PVC creation.

## Attach to virtual-machine

The output shape plugs directly into the repository's `virtual-machine`
module:

```hcl
module "web_data" {
  source = "./modules/protected-volume"

  namespace          = "default"
  storage_class_name = "harvester-longhorn"

  volumes = {
    "web-01-data" = { size = "100Gi" }
    "web-02-data" = { size = "100Gi" }
    "web-03-data" = { size = "100Gi" }
  }
}

module "web" {
  source = "./modules/virtual-machine"

  name_prefix    = "web"
  instance_count = 3
  root_image     = data.harvester_image.ubuntu_noble.id

  persistent_disks = {
    data = {
      volume_names = {
        web-01 = module.web_data.names["web-01-data"]
        web-02 = module.web_data.names["web-02-data"]
        web-03 = module.web_data.names["web-03-data"]
      }
    }
  }
}
```

The VM module attaches these with `existing_volume_name` and
`auto_delete = false`. Replacing the VM deletes its root/ephemeral disks but
keeps and reattaches these PVCs.

## Expansion

The module freezes `size` with `ignore_changes = [size]`. Terraform cannot
compare a new Kubernetes quantity with prior state inside validation, so a
normal variable edit cannot safely distinguish expansion from an accidental
shrink. A tested real-state plan confirmed that changing config from `100Gi`
to `10Gi` produces no size update.

Expansion is a separate break-glass operation:

1. Confirm StorageClass `allowVolumeExpansion`.
2. Snapshot/backup important data and verify restore instructions.
3. Obtain platform/data-owner approval.
4. Patch the PVC request through the approved operational tool or temporary,
   reviewed expansion configuration.
5. Check PVC conditions and backend capacity until expansion completes.
6. Expand/verify the guest filesystem if applicable.
7. Update this module's declared `size` to the new actual value for
   documentation (Terraform will continue ignoring it for mutation).

Never use this module's ordinary apply path to resize a protected volume.

## Immutable policy changes

Do not update these fields on existing PVCs:

- `storage_class_name`;
- `volume_mode`;
- `access_mode`.

The provider may plan an in-place update even though Kubernetes rejects it.
For any policy change:

1. Create a new protected volume under a new name.
2. Snapshot/backup the old volume.
3. Stop writes.
4. Copy or restore data.
5. Update the VM `persistent_disks` mapping.
6. Validate application data.
7. Retain the old PVC through the rollback window.
8. Decommission it through the process below.

## Decommissioning a volume

There is no `allow_destroy` variable. Terraform lifecycle settings cannot be
safely parameterized, and a one-line flag would make accidental deletion too
easy.

Decommission is intentionally a two-system, multi-step operation: Terraform
first relinquishes management without deleting data; a human then deletes the
PVC separately after independent safety checks.

### Step 1 — Prove it is no longer consumed

Provider 1.9.0 `attached_vm`/`state` is known to be inaccurate. Inspect actual
consumers:

```sh
kubectl -n <namespace> get vm,vmi,pod -o yaml
kubectl -n <namespace> get pvc <name> -o jsonpath='{.spec.volumeName}'
kubectl get volumeattachment -o yaml
```

Check VM/VMI claims, every Pod PVC reference, and VolumeAttachment records for
the bound PV. A stopped VM template reference does not reliably block PVC
deletion.

### Step 2 — Backup and approval

- Create and verify a backup/snapshot.
- Record restore instructions.
- Obtain the required data-owner/platform approval.

### Step 3 — Remove one volume from Terraform without destroying

Terraform `removed` blocks cannot address a single `for_each` instance; an
address such as `resource.this["web-01-data"]` is rejected with
`Resource instance keys not allowed`. For one volume, use an explicit state
operation after approval:

```sh
terraform state rm \
  'module.web_data.harvester_volume.this["web-01-data"]'
```

Then remove the same key from the root module's `volumes` map. Before running
any further apply, verify both sides:

```sh
terraform state list
kubectl -n default get pvc web-01-data
```

The PVC must still exist after it disappears from Terraform state. `state rm`
forgets the object; it does not call the Kubernetes delete API.

For decommissioning the entire module/resource collection, a resource-level
`removed` block with `destroy = false` may be used, but it applies to every
instance and must not be used when only one PVC should leave management.

### Step 4 — Break-glass deletion outside Terraform

Only after Terraform no longer owns the PVC and all safety checks pass, use
the audited break-glass Kubernetes identity to remove the protection label and
delete the PVC:

```sh
kubectl --as=<audited-break-glass-username> \
  -n default label pvc web-01-data \
  platform.harvester.io/protected-

kubectl --as=<audited-break-glass-username> \
  -n default delete pvc web-01-data
```

The admission policy rejects these operations for every normal identity,
including the Terraform service account. Confirm the backup and approval again
immediately before both commands. Do not reintroduce an unprotected
`harvester_volume` resource solely to delete it.

## Import existing PVCs

Declare the exact existing PVC name first:

```hcl
module "data" {
  source = "./modules/protected-volume"

  namespace          = "default"
  storage_class_name = "harvester-longhorn"

  volumes = {
    "existing-data" = {
      size = "100Gi"
    }
  }
}
```

Then import:

```sh
terraform import \
  'module.data.harvester_volume.this["existing-data"]' \
  default/existing-data
```

Run a plan and reconcile size, class, modes, labels, and tags before apply.
Never accept an immutable-field change or replacement plan for imported data.

## Known provider 1.9.0 caveats

- Create does not wait for PVC `Bound` or backend readiness.
- Update does not wait for resize completion.
- Invalid `size` reaches `resource.MustParse`; this module validates first.
- Immutable PVC fields are not marked ForceNew.
- `attached_vm` and derived `state` are unreliable due to importer logic.
- Volume read/import lists KubeVirt VMs in the namespace, so the Terraform
  identity needs `list` permission on `virtualmachines.kubevirt.io`.

## Outputs

| Output | Meaning |
| --- | --- |
| `names` | PVC names, ready for VM `persistent_disks` mapping |
| `ids` | `namespace/name` Terraform IDs |
| `storage_class_names` | Effective class per PVC |
| `volume_modes` | Effective `Block`/`Filesystem` value |
| `access_modes` | Effective access mode |
| `declared_sizes` | Values currently declared in `var.volumes`; documentation only because size mutation is ignored |
| `observed_sizes` | Values last observed from the provider/Kubernetes object; not proof backend/guest expansion completed |
| `phases` | Observed PVC phase; apply may finish before `Bound` |

The module deliberately does not output provider `attached_vm` or `state` as
trusted operational facts.

## Platform CI requirements

For production workspaces, parse saved plan JSON and block:

- any `harvester_volume` delete or replacement;
- size decrease;
- StorageClass, volume mode, or access mode change;
- module removal without an approved `removed { destroy = false }` block.

Also require remote state encryption, locking/versioning, Kubernetes RBAC that
restricts PVC deletion, scheduled backups, and tested restore procedures.

## Verification

```sh
terraform fmt -recursive -check
terraform validate
terraform test
```
