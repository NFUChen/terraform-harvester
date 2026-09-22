variable "name_prefix" {
  description = "DNS-compatible prefix used to name VMs. Instances are named <prefix>-01, <prefix>-02, and so on."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name_prefix)) && length(var.name_prefix) <= 58
    error_message = "name_prefix must be a lowercase DNS-compatible name no longer than 58 characters."
  }
}

variable "instance_count" {
  description = "Number of identically configured VMs to create."
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 1 && var.instance_count <= 99 && floor(var.instance_count) == var.instance_count
    error_message = "instance_count must be an integer between 1 and 99."
  }
}

variable "namespace" {
  description = "Harvester namespace in which to create the VMs, PVCs, and cloud-init secrets."
  type        = string
  default     = "default"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a valid lowercase Kubernetes DNS label."
  }
}

variable "description" {
  description = "Description applied to every VM."
  type        = string
  default     = null
}

variable "labels" {
  description = "Kubernetes labels applied to every VM. Values must satisfy Kubernetes label rules."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Harvester tags applied to every VM. Use ssh-user to define the default guest username when compatible with the supplied cloud-init."
  type        = map(string)
  default     = {}
}

variable "cpu" {
  description = "Number of virtual CPU cores per VM."
  type        = number
  default     = 2

  validation {
    condition     = var.cpu >= 1 && floor(var.cpu) == var.cpu
    error_message = "cpu must be a positive integer."
  }
}

variable "cpu_model" {
  description = "Optional KubeVirt CPU model, for example host-passthrough."
  type        = string
  default     = null
}

variable "memory" {
  description = "Memory limit per VM as a Kubernetes quantity."
  type        = string
  default     = "4Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$", var.memory))
    error_message = "memory must be a Kubernetes quantity such as 4Gi or 4096Mi."
  }
}

variable "resource_requests" {
  description = "Optional explicit CPU and memory requests. Leave null to let Harvester's overcommit webhook manage requests."
  type = object({
    cpu    = optional(string)
    memory = optional(string)
  })
  default  = null
  nullable = true
}

variable "machine_type" {
  description = "Optional machine type, commonly q35."
  type        = string
  default     = null
}

variable "set_hostname_from_instance_name" {
  description = "Set each VM's hostname to its instance name (<name_prefix>-NN). Disable when cloud-init or DHCP owns the guest hostname."
  type        = bool
  default     = true
}

variable "reserved_memory" {
  description = "Optional reserved memory as a Kubernetes quantity."
  type        = string
  default     = null
}

variable "cpu_pinning" {
  description = "Enable dedicated CPU placement. Requires CPU manager support on a schedulable node."
  type        = bool
  default     = false
}

variable "isolate_emulator_thread" {
  description = "Allocate an additional dedicated CPU to isolate the emulator thread. Requires cpu_pinning."
  type        = bool
  default     = false
}

variable "node_selector" {
  description = "Node labels used to constrain VM scheduling."
  type        = map(string)
  default     = {}
}

variable "efi" {
  description = "Enable EFI firmware."
  type        = bool
  default     = true
}

variable "secure_boot" {
  description = "Enable Secure Boot and SMM. Requires efi."
  type        = bool
  default     = false
}

variable "tpm" {
  description = "Attach a virtual TPM device."
  type        = bool
  default     = false
}

variable "run_strategy" {
  description = "KubeVirt VM run strategy."
  type        = string
  default     = "RerunOnFailure"

  validation {
    condition     = contains(["Always", "Manual", "Halted", "RerunOnFailure"], var.run_strategy)
    error_message = "run_strategy must be Always, Manual, Halted, or RerunOnFailure."
  }
}

variable "restart_after_update" {
  description = "Restart running VMs after updates. Effective only for Always and RerunOnFailure."
  type        = bool
  default     = true
}

variable "create_initial_snapshot" {
  description = "Create <vm-name>-initial after each VM first becomes ready. Snapshot creation is asynchronous."
  type        = bool
  default     = false
}

variable "root_image" {
  description = "Harvester image ID (name or namespace/name) used to clone the root disk. Set null for an empty root disk."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.root_image == null || length(split("/", var.root_image)) <= 2
    error_message = "root_image must be a name or namespace/name."
  }
}

variable "root_disk_size" {
  description = "Root disk size as a Kubernetes quantity."
  type        = string
  default     = "40Gi"

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$", var.root_disk_size))
    error_message = "root_disk_size must be a Kubernetes quantity such as 40Gi."
  }
}

variable "root_disk_bus" {
  description = "Root disk bus."
  type        = string
  default     = "virtio"

  validation {
    condition     = contains(["virtio", "sata", "scsi"], var.root_disk_bus)
    error_message = "root_disk_bus must be virtio, sata, or scsi."
  }
}

variable "root_disk_boot_order" {
  description = "Root disk boot order; zero leaves it unset."
  type        = number
  default     = 1

  validation {
    condition     = var.root_disk_boot_order >= 0 && floor(var.root_disk_boot_order) == var.root_disk_boot_order
    error_message = "root_disk_boot_order must be a non-negative integer."
  }
}

variable "root_disk_storage_class_name" {
  description = "Storage class for an empty root disk. For image-backed disks, omit this because the image determines the storage class."
  type        = string
  default     = null
}

variable "ephemeral_disks" {
  description = "VM-owned data disks. The module creates their PVCs and always deletes them with the VM. Never store unique data here."
  type = map(object({
    size               = string
    bus                = optional(string, "virtio")
    cache_mode         = optional(string)
    boot_order         = optional(number, 0)
    image              = optional(string)
    storage_class_name = optional(string)
    volume_mode        = optional(string, "Block")
    access_mode        = optional(string, "ReadWriteMany")
  }))
  default = {}

  validation {
    condition = alltrue([
      for name in keys(var.ephemeral_disks) :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", name)) &&
      !contains(["rootdisk", "cloudinitdisk"], name)
    ])
    error_message = "Ephemeral disk names must be lowercase DNS-compatible names and cannot be rootdisk or cloudinitdisk."
  }

  validation {
    condition = alltrue([
      for disk in values(var.ephemeral_disks) :
      can(regex("^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$", disk.size))
    ])
    error_message = "Every ephemeral disk size must be a Kubernetes quantity such as 20Gi."
  }

  validation {
    condition = alltrue([
      for disk in values(var.ephemeral_disks) :
      contains(["virtio", "sata", "scsi"], disk.bus)
    ])
    error_message = "Ephemeral disk bus must be virtio, sata, or scsi."
  }

  validation {
    condition = alltrue([
      for disk in values(var.ephemeral_disks) :
      disk.cache_mode == null || contains(["none", "writeback", "writethrough"], disk.cache_mode)
    ])
    error_message = "Ephemeral disk cache_mode must be none, writeback, or writethrough."
  }

  validation {
    condition = alltrue([
      for disk in values(var.ephemeral_disks) :
      disk.image == null || length(split("/", disk.image)) <= 2
    ])
    error_message = "Ephemeral disk image must be a name or namespace/name."
  }

  validation {
    condition = alltrue([
      for disk in values(var.ephemeral_disks) :
      disk.image == null || disk.storage_class_name == null
    ])
    error_message = "storage_class_name must be omitted for image-backed ephemeral disks; the image determines it."
  }

  validation {
    condition = alltrue([
      for disk in values(var.ephemeral_disks) :
      contains(["Block", "Filesystem"], disk.volume_mode) &&
      contains(["ReadWriteOnce", "ReadOnlyMany", "ReadWriteMany"], disk.access_mode)
    ])
    error_message = "Ephemeral disk volume_mode/access_mode is not supported."
  }
}

variable "persistent_disks" {
  description = "Externally managed PVCs attached per VM. Each disk must map every instance name to a distinct existing PVC. The module never deletes these PVCs."
  type = map(object({
    volume_names = map(string)
    bus          = optional(string, "virtio")
    cache_mode   = optional(string)
    boot_order   = optional(number, 0)
    hot_plug     = optional(bool, false)
  }))
  default = {}

  validation {
    condition = alltrue([
      for name in keys(var.persistent_disks) :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", name)) &&
      !contains(["rootdisk", "cloudinitdisk"], name)
    ])
    error_message = "Persistent disk names must be lowercase DNS-compatible names and cannot be rootdisk or cloudinitdisk."
  }

  validation {
    condition = alltrue([
      for disk in values(var.persistent_disks) :
      contains(["virtio", "sata", "scsi"], disk.bus)
    ])
    error_message = "Persistent disk bus must be virtio, sata, or scsi."
  }

  validation {
    condition = alltrue([
      for disk in values(var.persistent_disks) :
      disk.cache_mode == null || contains(["none", "writeback", "writethrough"], disk.cache_mode)
    ])
    error_message = "Persistent disk cache_mode must be none, writeback, or writethrough."
  }

  validation {
    condition = alltrue(flatten([
      for disk in values(var.persistent_disks) : [
        for volume_name in values(disk.volume_names) :
        can(regex("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$", volume_name))
      ]
    ]))
    error_message = "Every persistent volume name must be a non-empty DNS-compatible PVC name."
  }

  validation {
    condition = alltrue([
      for disk in values(var.persistent_disks) :
      length(values(disk.volume_names)) == length(toset(values(disk.volume_names)))
    ])
    error_message = "Each persistent disk must use a distinct PVC for every VM instance."
  }
}

variable "cdroms" {
  description = "CD-ROM devices, optionally backed by a Harvester image. CD-ROMs are never treated as persistent data disks."
  type = map(object({
    image      = optional(string)
    bus        = optional(string, "sata")
    boot_order = optional(number, 0)
  }))
  default = {}

  validation {
    condition = alltrue([
      for name in keys(var.cdroms) :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", name)) &&
      !contains(["rootdisk", "cloudinitdisk"], name)
    ])
    error_message = "CD-ROM names must be lowercase DNS-compatible names and cannot be rootdisk or cloudinitdisk."
  }

  validation {
    condition = alltrue([
      for cdrom in values(var.cdroms) : contains(["sata", "scsi"], cdrom.bus)
    ])
    error_message = "CD-ROM bus must be sata or scsi."
  }

  validation {
    condition = alltrue([
      for cdrom in values(var.cdroms) :
      cdrom.image == null || length(split("/", cdrom.image)) <= 2
    ])
    error_message = "CD-ROM image must be a name or namespace/name."
  }
}

variable "network_interfaces" {
  description = "VM network interfaces. Empty network_name selects the management network and defaults to masquerade; named networks default to bridge."
  type = list(object({
    name           = string
    network_name   = optional(string)
    type           = optional(string)
    model          = optional(string, "virtio")
    mac_address    = optional(string)
    wait_for_lease = optional(bool, false)
    boot_order     = optional(number, 0)
  }))
  default = [{ name = "nic-1" }]

  validation {
    condition     = length(var.network_interfaces) >= 1
    error_message = "At least one network interface is required."
  }

  validation {
    condition     = length(var.network_interfaces) == length(toset([for nic in var.network_interfaces : nic.name]))
    error_message = "Every network interface name must be unique."
  }

  validation {
    condition = alltrue([
      for nic in var.network_interfaces : nic.type == null || contains(["bridge", "masquerade"], nic.type)
    ])
    error_message = "Network interface type must be bridge or masquerade when specified."
  }

  validation {
    condition = alltrue([
      for nic in var.network_interfaces : contains(["virtio", "e1000", "e1000e", "ne2k_pco", "pcnet", "rtl8139"], nic.model)
    ])
    error_message = "A network interface model is not supported by the Harvester provider."
  }
}

variable "cloudinit" {
  description = "Cloud-init settings. Set enabled=false to omit cloud-init. Type must be noCloud or configDrive. A distinct Secret is created per VM when enabled."
  type = object({
    enabled      = optional(bool, true)
    type         = optional(string, "noCloud")
    user_data    = optional(string, "#cloud-config\n")
    network_data = optional(string, "")
  })
  default = {}

  validation {
    condition     = contains(["noCloud", "configDrive"], var.cloudinit.type)
    error_message = "cloudinit.type must be noCloud or configDrive."
  }
}

variable "ssh_keys" {
  description = "Harvester SSH KeyPair IDs (namespace/name). When cloud-init is Secret-backed, each public key must already exist in cloudinit.user_data under ssh_authorized_keys."
  type        = list(string)
  default     = []
}

variable "inputs" {
  description = "Optional KubeVirt input devices."
  type = list(object({
    name = string
    type = optional(string, "tablet")
    bus  = optional(string, "usb")
  }))
  default = []
}

variable "host_devices" {
  description = "Optional host devices to attach. device_name is the Kubernetes resource name exposed by the cluster."
  type = list(object({
    name        = string
    device_name = string
  }))
  default = []
}

variable "timeouts" {
  description = "Terraform operation timeouts. Increase create/update when waiting for guest leases or slow image clones."
  type = object({
    create = optional(string, "10m")
    read   = optional(string, "2m")
    update = optional(string, "10m")
    delete = optional(string, "10m")
  })
  default = {}
}
