variable "namespace" {
  description = "Harvester namespace that holds every volume in this module call."
  type        = string
  default     = "default"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a valid Kubernetes DNS-1123 label (lowercase alphanumeric and '-', 1-63 characters, alphanumeric start and end)."
  }
}

variable "storage_class_name" {
  description = "Default Harvester StorageClass for every volume. Required, because relying on the cluster default class would let a cluster-side change silently place future volumes on different storage."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$", var.storage_class_name)) && length(var.storage_class_name) <= 253
    error_message = "storage_class_name must be a valid Kubernetes DNS-1123 subdomain: dot-separated labels of 1-63 characters, 253 characters total."
  }
}

variable "volume_mode" {
  description = "Default Kubernetes volume mode for every volume."
  type        = string
  default     = "Block"

  validation {
    condition     = contains(["Block", "Filesystem"], var.volume_mode)
    error_message = "volume_mode must be Block or Filesystem."
  }
}

variable "access_mode" {
  description = "Default Kubernetes access mode. ReadWriteOnce is the safe default: a normal guest filesystem must not be mounted by several VMs at once."
  type        = string
  default     = "ReadWriteOnce"

  validation {
    condition     = contains(["ReadWriteOnce", "ReadOnlyMany", "ReadWriteMany"], var.access_mode)
    error_message = "access_mode must be ReadWriteOnce, ReadOnlyMany, or ReadWriteMany."
  }
}

variable "labels" {
  description = "Labels applied to every volume, merged with module-managed labels."
  type        = map(string)
  default     = {}
}

variable "tags" {
  description = "Harvester tags applied to every volume."
  type        = map(string)
  default     = {}
}

variable "delete_timeout" {
  description = "Timeout used when a volume is eventually removed through the documented decommission workflow. PVC deletion can block on finalizers or active consumers."
  type        = string
  default     = "10m"
}

variable "volumes" {
  description = "Volumes to manage, keyed by the exact PVC name. The key is the Kubernetes object identity, so renaming a key means creating a different volume, not renaming an existing one."
  type = map(object({
    size               = string
    storage_class_name = optional(string)
    volume_mode        = optional(string)
    access_mode        = optional(string)
    description        = optional(string)
    labels             = optional(map(string), {})
    tags               = optional(map(string), {})
  }))

  validation {
    condition     = length(var.volumes) > 0
    error_message = "volumes must declare at least one volume."
  }

  validation {
    condition = alltrue([
      for name in keys(var.volumes) :
      can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$", name)) && length(name) <= 253
    ])
    error_message = "Every volumes key must be a valid DNS-1123 subdomain PVC name: lowercase labels of 1-63 characters separated by single dots, at most 253 characters total."
  }

  validation {
    condition = alltrue([
      for volume in values(var.volumes) :
      can(regex("^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$", volume.size))
    ])
    error_message = "Every volume size must be a Kubernetes quantity such as 100Gi. The provider parses this with MustParse, so an invalid value can crash the provider instead of failing cleanly."
  }

  validation {
    condition = alltrue([
      for volume in values(var.volumes) :
      volume.storage_class_name == null || (
        can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$", volume.storage_class_name)) &&
        length(volume.storage_class_name) <= 253
      )
    ])
    error_message = "A per-volume storage_class_name override must be a valid Kubernetes DNS-1123 subdomain of at most 253 characters."
  }

  validation {
    condition = alltrue([
      for volume in values(var.volumes) :
      volume.volume_mode == null || contains(["Block", "Filesystem"], volume.volume_mode)
    ])
    error_message = "A per-volume volume_mode override must be Block or Filesystem."
  }

  validation {
    condition = alltrue([
      for volume in values(var.volumes) :
      volume.access_mode == null || contains(["ReadWriteOnce", "ReadOnlyMany", "ReadWriteMany"], volume.access_mode)
    ])
    error_message = "A per-volume access_mode override must be ReadWriteOnce, ReadOnlyMany, or ReadWriteMany."
  }
}
