# virtual-machine module

Creates a pool of Harvester VMs with explicit storage ownership rules. The
module targets `harvester/harvester = 1.9.0`.

## Storage model

The module intentionally exposes three separate storage APIs:

| Input | Ownership | Delete with VM | Intended use |
| --- | --- | --- | --- |
| Root disk | VM module | Always | Rebuildable operating system |
| `ephemeral_disks` | VM module | Always | Cache, temporary workspace, rebuildable data |
| `persistent_disks` | External resource/module | Never | Unique application data that must survive VM replacement |
| `cdroms` | VM module | With VM | Installation or recovery media |

Changing the root image, root storage class, ephemeral disk topology,
persistent PVC mapping, or CD-ROM topology changes a per-VM storage
fingerprint. Terraform then plans a VM replacement instead of attempting an
in-place update that Harvester's webhook would reject.

Provider 1.9.0 imports Harvester's generated `cloudinitdisk` into the resource
`disk` list even though configuration declares it through the separate
`cloudinit` block. The module ignores raw `disk` drift to eliminate this
permanent phantom diff. This does not hide caller storage changes: all
caller-configurable disk categories are included in the replacement
fingerprint above.

A replacement deletes the VM-owned root and ephemeral PVCs. Persistent PVCs
are externally managed and reattached to the replacement VM.

## Basic usage

```hcl
module "web" {
  source = "./modules/virtual-machine"

  name_prefix    = "web"
  instance_count = 3
  namespace      = "default"

  cpu    = 2
  memory = "4Gi"

  root_image     = harvester_image.ubuntu_noble.id
  root_disk_size = "40Gi"

  ephemeral_disks = {
    cache = {
      size = "20Gi"
    }
  }

  network_interfaces = [{
    name           = "nic-1"
    wait_for_lease = true
  }]

  cloudinit = {
    user_data = <<-YAML
      #cloud-config
      user: ubuntu
      package_update: true
      packages:
        - qemu-guest-agent
      runcmd:
        - systemctl enable --now qemu-guest-agent
    YAML
  }
}
```

## Persistent volumes

Create important volumes outside this module so they have stable Terraform
addresses and their own lifecycle policy. The VM module only attaches them as
existing PVCs and always sets `auto_delete = false`.

```hcl
resource "harvester_volume" "web_data" {
  for_each = toset(["web-01", "web-02", "web-03"])

  name      = "${each.key}-data"
  namespace = "default"
  size      = "100Gi"

  lifecycle {
    prevent_destroy = true
  }
}

module "web" {
  source = "./modules/virtual-machine"

  name_prefix    = "web"
  instance_count = 3
  root_image     = harvester_image.ubuntu_noble.id

  persistent_disks = {
    data = {
      volume_names = {
        web-01 = harvester_volume.web_data["web-01"].name
        web-02 = harvester_volume.web_data["web-02"].name
        web-03 = harvester_volume.web_data["web-03"].name
      }
    }
  }
}
```

Every persistent disk must provide one distinct PVC name for every VM. Missing
mappings and duplicate PVC names fail during planning.

## CD-ROMs

```hcl
cdroms = {
  installer = {
    image      = harvester_image.ubuntu_iso.id
    boot_order = 1
  }
}
```

CD-ROMs are separate from data disks and support only SATA or SCSI buses.

## Replacement and availability

Storage topology and cloud-init configuration changes replace the affected
VM. Because old and new VMs use the same Kubernetes name,
`create_before_destroy` cannot be used. A pool-wide image change may replace
all instances concurrently and cause an outage. Production rollouts should
use two module calls with different prefixes (blue/green), move traffic, and
then retire the old pool.

Reducing `instance_count` destroys the highest-numbered instances and their
root/ephemeral PVCs. Review every saved plan before applying a scale-down.

## Cloud-init

The module creates one `harvester_cloudinit_secret` per VM. Avoid plaintext
passwords because user data is stored in Terraform state and a Kubernetes
Secret. Prefer SSH public keys and encrypted remote state.

Cloud-init is only read by the guest on first boot. Provider 1.9.0's VM
resource references the Secret only by its static name, so an in-place
Secret update alone would silently do nothing to a running VM. The module
hashes `enabled`, `type`, `user_data`, and `network_data` into a fingerprint
and wires it through `replace_triggered_by`, the same mechanism used for
storage, so any real cloud-init change replaces the VM instead of leaving it
running stale configuration. The trigger stores a digest, not the raw
payload, so cloud-init content is never duplicated into that resource's
state or plan output.

## Outputs

| Name | Description |
| --- | --- |
| `instance_names` | Ordered VM names. |
| `ids` | VM IDs keyed by instance name. |
| `node_names` | Harvester node names keyed by instance. |
| `states` | Provider-derived VM states. |
| `network_interfaces` | Full VM interface state. |
| `primary_ip_addresses` | First interface IP keyed by instance. |
| `cloudinit_secret_names` | Cloud-init Secret names. |

## Verification

```sh
terraform fmt -recursive -check
terraform validate
terraform test
```

Tests cover storage ownership, per-instance persistent PVC mapping, reserved
disk names, CD-ROM rendering, and the cloud-init replacement fingerprint.
