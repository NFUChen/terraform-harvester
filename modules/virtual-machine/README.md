# virtual-machine module

Creates exactly one Harvester VM. The module targets `harvester/harvester = 1.9.0`.

## Storage model

| Input | Ownership | Delete with VM | Intended use |
| --- | --- | --- | --- |
| Root disk | VM module | Always | Rebuildable operating system |
| `ephemeral_disks` | VM module | Always | Cache, temporary workspace, rebuildable data |
| `persistent_disks` | External resource/module | Never | Application data that must survive VM replacement |
| `cdroms` | VM module | With VM | Installation or recovery media |

Changing caller-configurable storage or cloud-init changes a fingerprint that replaces the VM. Provider 1.9.0 imports Harvester's generated `cloudinitdisk` into the resource `disk` list, so raw disk drift is ignored; the storage fingerprint ensures real caller changes remain replacement-triggering.

## Basic usage

```hcl
module "web" {
  source = "./modules/virtual-machine"

  name      = "web-01"
  namespace = "default"

  cpu    = 2
  memory = "4Gi"

  root_image     = harvester_image.ubuntu_noble.id
  root_disk_size = "40Gi"

  ephemeral_disks = {
    cache = { size = "20Gi" }
  }

  network_interfaces = [{
    name           = "nic-1"
    wait_for_lease = true
  }]

  cloudinit = {
    user_data = <<-YAML
      #cloud-config
      user: ubuntu
      packages: [qemu-guest-agent]
      runcmd:
        - systemctl enable --now qemu-guest-agent
    YAML
  }
}
```

## Persistent volumes

Create important volumes outside this module. The VM only attaches them and always sets `auto_delete = false`.

```hcl
resource "harvester_volume" "web_data" {
  name      = "web-01-data"
  namespace = "default"
  size      = "100Gi"

  lifecycle {
    prevent_destroy = true
  }
}

module "web" {
  source = "./modules/virtual-machine"

  name       = "web-01"
  root_image = harvester_image.ubuntu_noble.id

  persistent_disks = {
    data = {
      existing_volume_name = harvester_volume.web_data.name
    }
  }
}
```

Each persistent disk requires one non-empty DNS-compatible PVC name. Attaching the same PVC under multiple disk names is rejected.

## Replacement and cloud-init

Storage topology and cloud-init changes replace the VM. The Kubernetes name is unchanged, so `create_before_destroy` cannot be used. Root and ephemeral PVCs are VM-owned and deleted on replacement; persistent PVCs are externally managed and reattached.

The module creates one `harvester_cloudinit_secret` when cloud-init is enabled. Cloud-init payload changes replace the VM because guests only consume cloud-init on first boot. Avoid plaintext credentials because cloud-init is stored in Terraform state and a Kubernetes Secret.

## Outputs

`name`, `id`, `node_name`, `state`, `network_interfaces`, `primary_ip_address`, and `cloudinit_secret_name` are singleton values. `cloudinit_secret_name` is `null` when cloud-init is disabled.

## Verification

```sh
terraform fmt -recursive -check
terraform validate
terraform test
```
