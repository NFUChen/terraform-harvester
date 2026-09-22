# harvester_volume provider 1.9.0 API reference

## Resource model

`harvester_volume` wraps a Kubernetes `PersistentVolumeClaim` in the selected namespace.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <name>
  namespace: <namespace>
spec:
  accessModes:
    - ReadWriteMany
  volumeMode: Block
  storageClassName: <storage-class>
  resources:
    requests:
      storage: 10Gi
```

## Terraform-to-PVC mapping

| Terraform field | PVC location | Notes |
|---|---|---|
| `name` | `metadata.name` | Required; changing identity requires replacement/import under a new ID |
| `namespace` | `metadata.namespace` | Optional; provider default `default`; changing identity requires replacement/import under a new ID |
| `size` | `spec.resources.requests.storage` | Default `1Gi`; constructor uses `resource.MustParse` |
| `storage_class_name` | `spec.storageClassName` | Optional+Computed; immutable in Kubernetes |
| `volume_mode` | `spec.volumeMode` | Default `Block`; `Block` or `Filesystem` |
| `access_mode` | first item in `spec.accessModes` | Default `ReadWriteMany`; RWO/ROX/RWX |
| `image` | `harvesterhci.io/imageId`-style builder annotation | Provider derives image-specific storage class |
| `description` | provider/Harvester description annotation | Mutable metadata |
| `labels` | `metadata.labels` | User labels |
| `tags` | encoded labels | Harvester tags |
| `phase` | `status.phase` | Computed |
| `state` | importer-derived | `Ready` or `In-use`, but attachment detection is unreliable in 1.9.0 |
| `attached_vm` | importer-derived | Buggy in 1.9.0; do not use for safety decisions |

## Create flow

1. Build a PVC with empty storage requests map.
2. Parse and set requested storage.
3. Set volume mode and access mode.
4. If `image` is present:
   - normalize to namespace/name;
   - write the image annotation;
   - derive storage class with `builder.BuildImageStorageClassName("", imageName)`.
5. Process `storage_class_name`; reject it if it conflicts with the image-derived value.
6. Create the PVC through CoreV1 Kubernetes client.
7. Import the returned object immediately.

Create does not use the configured create timeout for a readiness waiter. It does not wait for Bound or backend readiness.

## Update flow

1. GET existing PVC.
2. Re-run the same constructor processors against the existing object.
3. Issue a normal PVC Update.
4. Read the PVC back.

Provider schema does not model Kubernetes immutability. Expect API rejection for storage class, volume mode, and similar immutable changes. Size expansion may be accepted only when the storage class and CSI backend support it. Shrink is rejected. The configured create/read/update schema timeouts are not used by readiness waiters in these paths; update immediately reads the PVC after the API update and does not wait for resize completion.

## Delete flow

1. DELETE the PVC.
2. Poll until GET returns NotFound.
3. Default delete timeout is 5 minutes.

Pending state is hardcoded as `Active`; target is `Removed`. Finalizers or active Pod use may delay deletion and cause timeout, but a stopped VM merely referencing the PVC does not reliably block deletion. Never treat VM references or CSI attachment state as a substitute for `prevent_destroy` and policy controls.

## Import and data source

Both use direct GET by namespace/name. Import ID:

```text
<namespace>/<name>
```

The data source performs no alternate lookup and returns an error if the PVC does not exist.

## Attachment importer bug

Provider 1.9.0 code conceptually does:

```go
for _, vm := range allVMsInNamespace {
    for _, vol := range vm.Spec.Template.Spec.Volumes {
        if vol.PersistentVolumeClaim != nil && vol.PersistentVolumeClaim.ClaimName != "" {
            attachedList = append(attachedList, ref.Construct(obj.Namespace, obj.Name))
        }
    }
}
```

It never checks:

```go
vol.PersistentVolumeClaim.ClaimName == obj.Name
```

Consequences:

- Any VM with any PVC can make every volume in the namespace appear `In-use`.
- The list can contain duplicate entries.
- Entries identify the volume (`obj.Namespace/obj.Name`), not the VM being iterated.
- `state` and `attached_vm` are unsuitable for deletion authorization or accurate inventory.

Verify actual attachment from VM specs, VMI specs, pods, and Kubernetes VolumeAttachment objects.

## Schema caveats

### `storage_class_name` Optional+Computed

If omitted, Terraform can retain a previously computed state value during update. For image-backed volumes this can conflict with a newly selected image's derived storage class. Wrapper modules should either:

- resolve the image's actual storage class explicitly; or
- treat image changes as replacement-only and avoid updates.

For protected data, rejecting image changes is safer than automatic replacement.

### Invalid size handling

The constructor calls `resource.MustParse(size)` rather than returning a parse diagnostic. The schema does not validate quantity syntax. A wrapper module should validate Kubernetes quantity format before the provider runs to reduce provider panic risk.

### No ForceNew annotations

No volume fields are marked ForceNew in the provider schema. Terraform may show in-place updates for changes Kubernetes will reject. A wrapper module must encode lifecycle policy itself.

## Recommended wrapper-module contract

Separate two contracts rather than exposing every provider field without policy.

### Protected empty data volume

Required inputs:

- stable name/key;
- namespace;
- size;
- explicit storage class.

Optional inputs:

- labels/tags/description;
- volume mode/access mode;
- timeouts.

Policy:

- `prevent_destroy = true` (static module policy);
- validate quantity and enums;
- immutable fields rejected or replaced through an explicit migration workflow;
- size may only grow;
- output name/id for VM `existing_volume_name` attachment.

### Image clone volume

Use a separate resource/module path because image implies a different storage class and replacement model. Policy:

- accept image ID and size;
- do not accept storage class override;
- resolve and expose actual storage class;
- treat image changes as destructive replacement;
- do not use for mutable application data.

## Suggested outputs

```hcl
output "names" {
  value = { for key, volume in harvester_volume.this : key => volume.name }
}

output "ids" {
  value = { for key, volume in harvester_volume.this : key => volume.id }
}

output "storage_class_names" {
  value = { for key, volume in harvester_volume.this : key => volume.storage_class_name }
}

output "phases" {
  value = { for key, volume in harvester_volume.this : key => volume.phase }
}
```

Do not promote `attached_vm` as a trustworthy output in 1.9.0.

## Investigated sources

- Terraform Registry `harvester_volume` resource and data source for 1.9.0.
- `internal/provider/volume/schema_volume.go`
- `internal/provider/volume/resource_volume.go`
- `internal/provider/volume/resource_volume_constructor.go`
- `internal/provider/volume/datasource_volume.go`
- `pkg/importer/resource_volume_importer.go`
- `pkg/constants/constants_volume.go`
- Installed provider schema from `terraform providers schema -json`.
