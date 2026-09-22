# Harvester Volume Terraform 封裝建議

## 目的

本文件說明如何在 `harvester/harvester` provider 1.9.0 上安全封裝
`harvester_volume`，並與專案現有的 `virtual-machine` module 整合。

主要目標：

1. 重要資料不隨 VM replacement、scale-down 或 destroy 被刪除。
2. Terraform plan 能清楚表達 volume ownership。
3. 避免直接暴露 provider 的不安全預設與生命週期缺口。
4. 將 root/ephemeral storage 與 persistent application data 分離。
5. 讓 VM replacement 後可以重新掛回既有 PVC。

---

## Provider resource 的本質

`harvester_volume` 實際建立的是 namespaced Kubernetes
`PersistentVolumeClaim`，不是 Harvester 自訂 CRD：

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: web-01-data
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Block
  storageClassName: <storage-class>
  resources:
    requests:
      storage: 100Gi
```

因此 Kubernetes PVC 的 immutable fields、expansion、finalizer、Pod 使用狀態與
CSI backend 限制都會直接影響 Terraform 操作。

---

## Provider 1.9.0 的重要行為

### Schema defaults

| 欄位 | Provider 預設 |
| --- | --- |
| `namespace` | `default` |
| `size` | `1Gi` |
| `volume_mode` | `Block` |
| `access_mode` | `ReadWriteMany` |
| create/read/update schema timeout | 2 分鐘 |
| delete timeout | 5 分鐘 |

這些是 provider defaults，不是推薦的 storage architecture。

對一般「一台 VM 使用一顆 data disk」的情境，建議明確設定：

```hcl
volume_mode = "Block"
access_mode = "ReadWriteOnce"
```

`ReadWriteMany` 只應用於已確認下列條件的共享 storage：

- StorageClass/CSI driver 支援 multi-attach；
- Guest filesystem 或 application 支援 concurrent access；
- 已測試 failure、fencing 與資料一致性行為。

一般 ext4/xfs block filesystem 不應同時掛載到多台 VM。

---

## Provider 實作限制

### Create 不等待 volume ready

Create 成功後 provider 立即讀回 PVC，不等待：

- PVC `Bound`；
- Longhorn volume ready；
- Image population 完成；
- Replica ready；
- 實際 capacity 可用。

因此 `terraform apply` 成功只表示 PVC API object 已建立。

檢查：

```sh
kubectl -n <namespace> get pvc <name> -o yaml
```

若 volume readiness 是後續自動化的必要條件，應另外增加 readiness gate。

### Immutable fields 沒有 ForceNew

Provider schema 沒有將以下欄位標成 ForceNew：

- `storage_class_name`；
- `volume_mode`；
- `access_mode`；
- `image`。

Terraform 可能計畫 in-place update，但 Kubernetes/Harvester 最終會拒絕。

建議行為：

| 變更 | 建議處理方式 |
| --- | --- |
| StorageClass | 建立新 volume、搬移資料、切換掛載 |
| Volume mode | 建立新 volume、搬移資料 |
| Access mode | 視為 migration，不直接更新 |
| Image | 視為新 clone，不更新既有 persistent volume |
| Size 增加 | StorageClass 支援 expansion 時允許 |
| Size 減少 | 禁止；建立較小新 volume 後搬移資料 |

對 protected volume，不應自動 replacement，因 replacement 代表刪除原 PVC。

### Size parser 風險

Provider 使用 `resource.MustParse(size)`，schema 沒有 quantity validation。
Wrapper module 應先驗證 Kubernetes quantity，避免不合法輸入進入 provider：

```hcl
validation {
  condition = can(regex(
    "^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$",
    each.value.size,
  ))

  error_message = "size must be a Kubernetes quantity such as 100Gi."
}
```

### Resize 不等待完成

Update size 後 provider 立即 read，不等待：

- `status.capacity` 更新；
- CSI resize 完成；
- Filesystem resize 完成；
- Guest OS 看見新 capacity。

因此 apply 完成後仍應檢查 PVC condition、backend volume 與 guest filesystem。

### Delete 沒有安全檢查

Provider delete 會直接刪除 PVC，不會：

- 檢查 VM/VMI/Pod reference；
- detach；
- snapshot；
- backup；
- 要求人工確認。

Stopped VM template 仍引用 PVC，不代表 PVC 一定無法被刪除。PVC protection 可能在
active Pod 使用時延遲刪除，但不能當作可靠的 Harvester VM attachment lock。

### `attached_vm` 與 `state` 不可靠

Provider 1.9.0 importer 遍歷 namespace 中所有 VM 時，只檢查 VM 是否含任意 PVC，
沒有比對該 PVC claim name 是否為目前 volume。結果可能是：

- Namespace 中任何 VM 使用任何 PVC，其他 volume 也被標成 `In-use`；
- `attached_vm` 出現重複值；
- 值實際指向 volume namespace/name，而非 VM 名稱。

因此不要使用下列欄位做刪除授權或 operational inventory：

```hcl
attached_vm
state
```

安全檢查至少應包含：

```sh
kubectl -n <namespace> get vm,vmi,pod -o yaml
kubectl -n <namespace> get pvc <name> -o jsonpath='{.spec.volumeName}'
kubectl get volumeattachment -o yaml
```

檢查 VM/VMI volume claims、所有 Pod PVC references，再由 PVC 的 PV 名稱比對
`VolumeAttachment`。`VolumeAttachment` 直接引用 PV，不是 PVC。

### 額外 RBAC 需求

Provider 每次 read/import volume 時會 list 同 namespace 的 KubeVirt VM。
Terraform identity 除了 PVC 權限，也需要：

```text
list virtualmachines.kubevirt.io
```

否則 create refresh、data source read 和 import 都可能失敗。

---

## 建議的 ownership model

```text
Harvester image
    └── VM root disk
        └── VM-owned、可重建、auto-delete

Virtual-machine module
    ├── Root PVC
    │   └── VM-owned、auto-delete
    ├── Ephemeral PVC
    │   └── VM-owned、auto-delete
    └── existing_volume_name
        └── 只引用外部 persistent PVC、auto_delete=false

Protected-volume module
    └── Persistent PVC
        ├── 獨立 Terraform address
        ├── prevent_destroy=true
        ├── 獨立 backup/migration lifecycle
        └── VM replacement 後重新掛載
```

關鍵原則：

- OS/root disk 應可由 image 和 cloud-init 重建；
- Cache/temporary disk 可以跟 VM 一起刪除；
- 唯一資料必須放在獨立管理的 persistent volume；
- VM module 不應建立再 retain 一顆沒有獨立 Terraform resource 的 orphan PVC。

---

## 建議拆成兩種 module

### Protected empty data volume

用於 database/application data。

特性：

- 固定 `prevent_destroy = true`；
- 必須提供明確 StorageClass；
- 預設 `ReadWriteOnce`；
- 不接受 image；
- 允許 size expansion，但禁止 shrink；
- 不自動 replace immutable fields；
- output 可直接接到 VM module 的 `persistent_disks`。

### Image clone volume

用於 image clone、boot clone 或可重建 data clone。

特性：

- 接受 image 與 size；
- 不接受 storage class override；
- Image 變更視為 destructive replacement；
- 不應存放唯一 application data；
- 視用途決定是否需要 `prevent_destroy`。

不要將 protected application data 與 image clone 放進同一個 API，因兩者的 replacement
和 retention policy 不同。

---

## Protected volume module API 建議

```hcl
variable "namespace" {
  type    = string
  default = "default"
}

variable "name_suffix" {
  type    = string
  default = "data"
}

variable "storage_class_name" {
  type = string
}

variable "volume_mode" {
  type    = string
  default = "Block"
}

variable "access_mode" {
  type    = string
  default = "ReadWriteOnce"
}

variable "volumes" {
  type = map(object({
    size        = string
    description = optional(string)
    labels      = optional(map(string), {})
    tags        = optional(map(string), {})
  }))
}
```

Resource：

```hcl
resource "harvester_volume" "this" {
  for_each = var.volumes

  name      = "${each.key}-${var.name_suffix}"
  namespace = var.namespace

  size               = each.value.size
  storage_class_name = var.storage_class_name
  volume_mode        = var.volume_mode
  access_mode        = var.access_mode
  description        = each.value.description

  labels = merge(
    {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/instance"   = each.key
      "app.kubernetes.io/component"  = var.name_suffix
    },
    each.value.labels,
  )

  tags = each.value.tags

  lifecycle {
    prevent_destroy = true
  }

  timeouts {
    delete = "10m"
  }
}
```

`prevent_destroy` 不能由變數動態控制，因此 protected module 應固定保護。若需要
unprotected volume，應使用另一個明確命名的 module，而不是提供容易誤設的
`protected = false`。

---

## 建議 validation

### Namespace、suffix 與 volume key

驗證 Kubernetes DNS-compatible name，並限制最終名稱長度不超過 253 字元。

### Size

驗證 Kubernetes quantity 格式；另外用 CI plan policy 防止 shrink，因 variable
validation 無法直接比較 prior state。

### Storage mode

```hcl
validation {
  condition     = contains(["Block", "Filesystem"], var.volume_mode)
  error_message = "volume_mode must be Block or Filesystem."
}
```

### Access mode

```hcl
validation {
  condition = contains(
    ["ReadWriteOnce", "ReadOnlyMany", "ReadWriteMany"],
    var.access_mode,
  )

  error_message = "Unsupported access_mode."
}
```

### StorageClass

Protected volume 應強制非空 StorageClass，不依賴 cluster default，避免 default class
變更後，不同時間建立的 volume 落到不同 backend/policy。

---

## 建議 outputs

```hcl
output "names" {
  value = {
    for key, volume in harvester_volume.this : key => volume.name
  }
}

output "ids" {
  value = {
    for key, volume in harvester_volume.this : key => volume.id
  }
}

output "storage_class_names" {
  value = {
    for key, volume in harvester_volume.this :
    key => volume.storage_class_name
  }
}

output "phases" {
  value = {
    for key, volume in harvester_volume.this : key => volume.phase
  }
}
```

不要將 provider 1.9.0 的 `attached_vm` 或 `state` 宣稱為可信的 operational output。

---

## 與 virtual-machine module 整合

建立獨立 volumes：

```hcl
module "web_data" {
  source = "./modules/protected-volume"

  namespace          = "default"
  name_suffix        = "data"
  storage_class_name = "harvester-longhorn"

  volumes = {
    web-01 = { size = "100Gi" }
    web-02 = { size = "100Gi" }
    web-03 = { size = "100Gi" }
  }
}
```

掛載到 VM：

```hcl
module "web" {
  source = "./modules/virtual-machine"

  name_prefix    = "web"
  instance_count = 3
  root_image     = data.harvester_image.ubuntu_noble.id

  persistent_disks = {
    data = {
      volume_names = module.web_data.names
    }
  }
}
```

VM module 會針對 persistent disks 固定：

```hcl
existing_volume_name = <per-instance PVC>
auto_delete          = false
```

因此 VM replacement 時：

- Root PVC 刪除；
- Ephemeral PVC 刪除；
- Persistent PVC 保留；
- Replacement VM 重新掛載相同 PVC。

---

## Migration 與 immutable field 變更

Protected volume 的 StorageClass、volume mode 或 access mode 要變更時，建議流程：

1. 建立新 volume；
2. 建立 snapshot/backup；
3. 停止寫入；
4. 搬移或 restore 資料；
5. 驗證資料一致性；
6. 更新 VM `existing_volume_name`；
7. 替換或重啟 VM；
8. 驗證 application；
9. 經人工核准後才移除舊 volume 的 `prevent_destroy`；
10. 刪除舊 volume。

不要直接修改既有 PVC immutable fields，也不要讓 wrapper module 自動 destroy/recreate
protected volume。

---

## CI/CD policy 建議

正式環境至少加入：

1. Remote state encryption、locking、versioning；
2. Saved plan；
3. Plan JSON 檢查 PVC delete/replace；
4. Size shrink 檢查；
5. Protected volume delete 需要人工核准；
6. Terraform identity 與日常 VM operator 分離；
7. Harvester/Kubernetes RBAC 限制 PVC delete；
8. 定期 backup/snapshot 與 restore drill。

Plan policy 應阻擋：

```text
harvester_volume delete
harvester_volume replace
size shrink
storage_class_name change
volume_mode change
access_mode change
```

除非進入明確的 migration workflow。

---

## 建議的後續實作

1. 新增 `modules/protected-volume`；
2. 使用 Terraform tests 驗證名稱、quantity、enum 與 outputs；
3. 測試 `prevent_destroy`；
4. 測試與 `virtual-machine.persistent_disks` 的整合；
5. 在獨立非 production namespace 做 volume create/attach/detach/resize 測試；
6. 加入 CI plan policy；
7. 文件化 migration 與 recovery runbook。
