---
name: harvester-image
description: Harvester Terraform image management using harvester_image, VirtualMachineImage (VMI), image download/upload/export/clone, encryption/decryption, import, or image troubleshooting. Use whenever a user asks to create, inspect, migrate, debug, or generate Terraform for Harvester VM images, even if they only mention an ISO, qcow2, raw image, image URL, local image upload, PVC export, backingimage/CDI, or a stuck image state.
compatibility: Requires Terraform with the harvester/harvester provider and Harvester kubeconfig access; local upload requires provider support for file_path.
metadata:
  domain: harvester
  resource: harvester_image
---

# Harvester Image

Use this skill to produce correct, minimal Terraform for Harvester VM images and to reason about the provider's underlying Kubernetes and Steve APIs.

## First determine the intent

Collect only missing information:

1. Operation: create, look up, import, update metadata, delete, or troubleshoot.
2. Source: HTTP(S) download, local upload, PVC export, or encrypted/decrypted clone.
3. Required identity: Terraform label, Kubernetes `name`, `namespace`, and `display_name`.
4. Storage: default/backing-image or explicit storage class/CDI.
5. Integrity/security: optional SHA-512 checksum or clone security parameters.
6. Provider version when behavior depends on newer fields such as `file_path`.

Do not invent URLs, namespaces, storage classes, local paths, or source image identities. Ask for them when required.

## Generation workflow

1. Inspect existing `.tf` files and provider constraints before editing.
2. Follow existing Terraform naming and variable conventions.
3. Select exactly one source mode from the matrix below.
4. Emit only fields valid for that mode.
5. Add custom timeouts for large images or slow storage when appropriate.
6. Run `terraform fmt` and `terraform validate` when the repository is available. Run `terraform plan` only when credentials/backend access are available and the user permits it.
7. Explain replacements: `display_name`, `url`, `checksum`, `file_path`, and `storage_class_name` are ForceNew in the current provider implementation.

## Source matrix

| Intent | `source_type` | Required fields | Forbidden/irrelevant fields |
|---|---|---|---|
| Remote image | `download` | `url` | `file_path`, PVC fields, `security_parameters` |
| Local file | `upload` | `file_path` pointing to a readable regular file | `url`, PVC fields, `security_parameters` |
| Existing PVC | `export-from-volume` | `pvc_name`, `pvc_namespace` | `url`, `file_path`, `security_parameters` |
| Encrypt/decrypt image | `clone` | all three `security_parameters` keys | `url`, `file_path`, PVC fields |

The Harvester CRD also defines `restore`, but the Terraform provider's `harvester_image` schema does not accept it. Do not generate `source_type = "restore"` for this resource.

## Canonical Terraform patterns

### Download

```hcl
resource "harvester_image" "ubuntu" {
  name         = "ubuntu-2404"
  namespace    = "harvester-public"
  display_name = "Ubuntu 24.04"
  source_type  = "download"
  url          = var.ubuntu_image_url

  # Optional SHA-512 value, without guessing its representation.
  checksum = var.ubuntu_image_sha512

  timeouts {
    create = "30m"
    delete = "10m"
  }
}
```

### Local upload

```hcl
resource "harvester_image" "opensuse" {
  name         = "opensuse-156"
  namespace    = "default"
  display_name = "openSUSE Leap 15.6"
  source_type  = "upload"
  file_path    = var.opensuse_image_path

  timeouts {
    create = "30m"
  }
}
```

The file must be available on the machine running Terraform. The provider creates the VMI, waits for `Initialized=True`, then streams multipart form data to the Harvester Steve upload action. Do not replace `file_path` with a URL.

### Export from PVC

```hcl
resource "harvester_image" "from_volume" {
  name          = "golden-image"
  namespace     = "default"
  display_name  = "Golden image"
  source_type   = "export-from-volume"
  pvc_name      = "source-pvc"
  pvc_namespace = "default"
}
```

### Encrypted/decrypted clone

```hcl
resource "harvester_image" "encrypted" {
  name               = "ubuntu-encrypted"
  namespace          = "default"
  display_name       = "Ubuntu encrypted"
  source_type        = "clone"
  storage_class_name = harvester_storageclass.encryption.name

  security_parameters = {
    crypto_operation       = "encrypt"
    source_image_name      = harvester_image.ubuntu.name
    source_image_namespace = harvester_image.ubuntu.namespace
  }
}
```

`crypto_operation` must be `encrypt` or `decrypt`. Ensure the storage class and its secret configuration support the requested operation; never place encryption secrets directly in ordinary output or source unless the user explicitly accepts that risk.

## Backend and storage rules

- Provider documentation describes `backend` as `backing-image` or `cdi`, while current source code/CRD enum uses `backingimage` or `cdi`. This version-sensitive discrepancy must be verified against the installed provider schema before setting a non-default value:

  ```sh
  terraform providers schema -json
  ```

- Prefer omitting `backend` to use the provider default unless the user needs CDI.
- CDI requires `storage_class_name` in provider validation.
- `storage_class_name` is ForceNew. Changing it replaces the resource.
- `storage_class_parameters` and `volume_storage_class_name` are computed; do not configure them.

## Lookup and import

Look up by Kubernetes name:

```hcl
data "harvester_image" "ubuntu" {
  name      = "ubuntu-2404"
  namespace = "harvester-public"
}
```

Or by display name:

```hcl
data "harvester_image" "ubuntu" {
  namespace    = "harvester-public"
  display_name = "Ubuntu 24.04"
}
```

The data source requires either `name` or `display_name`. Prefer `name` because it maps to a direct API GET; display-name lookup lists the namespace and returns the first matching image.

Import format:

```sh
terraform import harvester_image.ubuntu harvester-public/ubuntu-2404
```

After import, run `terraform plan` and reconcile ForceNew fields carefully to avoid accidental replacement.

## API mental model

The Terraform resource primarily wraps the namespaced Harvester CRD:

```yaml
apiVersion: harvesterhci.io/v1beta1
kind: VirtualMachineImage
metadata:
  name: <name>
  namespace: <namespace>
spec:
  displayName: <display_name>
  sourceType: download | upload | export-from-volume | clone
```

CRUD uses the Kubernetes client for `VirtualMachineImage`. Local upload additionally invokes:

```text
POST /v1/harvester/harvesterhci.io.virtualmachineimages/{namespace}/{name}?action=upload&size={bytes}
Content-Type: multipart/form-data
form field: chunk
```

Authentication, TLS, proxy, and server host come from the configured kubeconfig REST transport. Never fabricate bearer tokens or disable TLS verification as a default fix.

Read `references/api.md` when translating Terraform to raw API objects, diagnosing status/conditions, or explaining provider internals.

## State and troubleshooting

The provider maps conditions to these Terraform states:

- no initialization message yet: `Initializing`
- initialized, not imported, download source: `Downloading`
- initialized, not imported, PVC export: `Exporting`
- initialized, not imported, other source: `Uploading`
- initialized and imported: `Active`
- not initialized with an initialization message: `Failed`

Troubleshoot in this order:

1. Confirm namespace/name and inspect `VirtualMachineImage` conditions.
2. For download, verify the URL is HTTP(S), reachable from the cluster, and serves a supported raw/qcow2/bootable ISO payload.
3. For upload, verify the local file exists, is regular/readable, and Terraform can reach the Harvester API for the full stream duration.
4. For PVC export, verify both PVC fields and that the PVC exists in the stated namespace.
5. For CDI, verify the storage class and CDI components.
6. For clone security operations, verify all security keys and source image identity.
7. Increase `timeouts.create` only after checking conditions; a larger timeout does not repair invalid input.
8. Treat transient upload messages containing `already exists` or `timeout waiting` as provider-retryable until the create context expires.

Useful inspection command:

```sh
kubectl -n <namespace> get virtualmachineimage <name> -o yaml
```

## Safety and output quality

- Never apply or destroy infrastructure unless explicitly requested.
- Do not expose kubeconfig contents, tokens, encryption passphrases, or secret data.
- Avoid hardcoding environment-specific paths and URLs when reusable variables fit the existing module style.
- State version assumptions when provider docs and implementation differ.
- Keep generated HCL minimal; do not include unrelated storage classes or secrets unless the requested operation requires them.
