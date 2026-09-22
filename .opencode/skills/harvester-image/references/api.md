# Harvester image API reference

This reference summarizes the behavior investigated from the current `terraform-provider-harvester` and Harvester source. Re-check the selected provider version before relying on implementation-specific details.

## Terraform-to-CRD mapping

| Terraform field | VirtualMachineImage field | Notes |
|---|---|---|
| `name` | `metadata.name` | Kubernetes name; required and unique within namespace |
| `namespace` | `metadata.namespace` | Namespaced resource |
| `display_name` | `spec.displayName` | Required; ForceNew in provider |
| `source_type` | `spec.sourceType` | Provider accepts download/upload/export-from-volume/clone |
| `url` | `spec.url` | HTTP(S), ForceNew; required for download |
| `checksum` | `spec.checksum` | SHA-512, ForceNew |
| `pvc_name` | `spec.pvcName` | Required for export-from-volume |
| `pvc_namespace` | `spec.pvcNamespace` | Required for export-from-volume |
| `backend` | `spec.backend` | Enum is version-sensitive; see discrepancy below |
| `storage_class_name` | storage-class annotation | Optional except CDI; ForceNew |
| `security_parameters.crypto_operation` | `spec.securityParameters.cryptoOperation` | encrypt/decrypt |
| `security_parameters.source_image_name` | `spec.securityParameters.sourceImageName` | clone only |
| `security_parameters.source_image_namespace` | `spec.securityParameters.sourceImageNamespace` | clone only |
| `description` | provider-managed annotation | Common provider field |
| `labels` | `metadata.labels` | User labels |
| `tags` | `metadata.labels` | Encoded through provider tag handling |
| `progress` | `status.progress` | Computed |
| `size` | `status.size` | Computed |
| `volume_storage_class_name` | `status.storageClassName` | Computed |
| `storage_class_parameters` | `spec.storageClassParameters` | Computed by Terraform schema |
| `state`, `message` | derived from `status.conditions` | Computed provider abstraction |

`file_path` is provider-local input. It is validated as a regular file and is not stored in the VirtualMachineImage CR.

## Kubernetes API shape

```yaml
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: ubuntu-2404
  namespace: harvester-public
spec:
  backend: backingimage
  displayName: Ubuntu 24.04
  sourceType: download
  url: https://example.invalid/ubuntu.qcow2
  checksum: <sha512>
```

The exact Kubernetes REST collection follows normal CRD conventions under the `harvesterhci.io/v1beta1` API group. Prefer `kubectl` or a typed/dynamic Kubernetes client rather than manually constructing that URL.

## CRUD lifecycle

### Create

1. Build the `VirtualMachineImage` object.
2. Create it through `HarvesterhciV1beta1().VirtualMachineImages(namespace).Create(...)`.
3. Set Terraform ID to `<namespace>/<name>`.
4. If `source_type=upload`, wait for the `Initialized=True` condition and stream the local file to the Steve action.
5. Poll until provider state is `Active` or timeout/failure.

### Read

- Split Terraform ID into namespace/name.
- GET the VMI through the Kubernetes client.
- A 404 clears Terraform state.
- Import spec/status values and derive state from conditions.

### Update

- GET the existing VMI.
- Apply mutable common/spec values.
- Update through the Kubernetes client.
- Read the resource back.

ForceNew fields prevent Terraform updates for:

- `display_name`
- `url`
- `checksum`
- `file_path`
- `storage_class_name`

### Delete

- Delete the VMI through the Kubernetes client.
- Poll through `Terminating`/`Active` until `Removed`.
- A 404 is treated as successfully removed.

## Upload action

After the controller reports `Initialized=True`, the provider sends:

```http
POST /v1/harvester/harvesterhci.io.virtualmachineimages/{namespace}/{name}?action=upload&size={file-size}
Content-Type: multipart/form-data; boundary=...

chunk=@<base-filename>
```

Important details:

- The URL is rooted at the Harvester API host from kubeconfig.
- The Kubernetes REST transport supplies authentication, TLS, and proxy settings.
- Only the base filename is sent, avoiding local path disclosure.
- The file is streamed through a pipe rather than fully loaded into memory.
- Provider retries errors containing `already exists` or `timeout waiting` every five seconds until context timeout.
- If upload fails, the provider attempts to delete the newly created VMI.

## Source validation

### download

- `url` must be supplied.
- Provider schema validates HTTP/HTTPS URLs.
- Supported documentation claims raw, qcow2, and bootable ISO.

### upload

- `file_path` must be supplied.
- It must exist and be a regular file.
- `file_path` must not be supplied for other source types.

### export-from-volume

- Both `pvc_name` and `pvc_namespace` must be supplied.

### clone

`security_parameters` is allowed only for clone and requires:

```hcl
security_parameters = {
  crypto_operation       = "encrypt" # or decrypt
  source_image_name      = "source-name"
  source_image_namespace = "source-namespace"
}
```

The Terraform validator checks key presence; the CRD enforces the crypto operation enum.

## Conditions and state derivation

Relevant conditions:

- `Initialized`
- `Imported`
- `RetryLimitExceeded`
- `BackingImageMissing`
- `MetadataReady`

Terraform state derivation currently focuses on `Initialized` and `Imported`:

| Initialized | Imported | Source | Terraform state |
|---|---|---|---|
| false/no message | any | any | Initializing |
| false/has message | any | any | Failed |
| true | false | download | Downloading |
| true | false | export-from-volume | Exporting |
| true | false | upload/clone | Uploading |
| true | true | any | Active |

A `Failed` state returns the initialization condition message as an error.

## Default timeouts

| Operation | Provider default |
|---|---:|
| create | 5 minutes |
| read | 2 minutes |
| update | 5 minutes |
| delete | 2 minutes |
| default | 2 minutes |

Image transfer frequently needs a longer explicit create timeout.

## Data source behavior

The `harvester_image` data source supports either:

- `name` + namespace: direct GET; or
- `display_name` + namespace: LIST all images, iterate, and return the first exact display-name match.

It errors if neither selector is supplied. Because display names may not be unique, prefer the Kubernetes name.

## Import

Terraform import ID format:

```text
<namespace>/<name>
```

Example:

```sh
terraform import harvester_image.ubuntu harvester-public/ubuntu-2404
```

## Known version discrepancy

Current provider documentation says backend values are `backing-image` and `cdi`; current provider source derives its allowed value from Harvester's VMI enum, whose current CRD source uses `backingimage` and `cdi`. Historical releases may differ. Confirm the installed provider's schema and behavior rather than copying either spelling blindly.

## Investigated sources

- Terraform Registry resource supplied by the user.
- `terraform-provider-harvester/docs/resources/image.md`
- `terraform-provider-harvester/docs/data-sources/image.md`
- `internal/provider/image/schema_image.go`
- `internal/provider/image/resource_image.go`
- `internal/provider/image/resource_image_constructor.go`
- `internal/provider/image/datasource_image.go`
- `internal/provider/image/validator.go`
- `pkg/importer/resource_image_importer.go`
- Harvester `pkg/apis/harvesterhci.io/v1beta1/image.go`
