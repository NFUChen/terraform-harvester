variable "instances" {
  description = "Worker VMs keyed by their exact stable name. Each address is a unique static VLAN address."
  type = map(object({
    address = string
    cpu     = optional(number)
    memory  = optional(string)
    persistent_disks = optional(map(object({
      existing_volume_name = string
      bus                  = optional(string, "virtio")
      cache_mode           = optional(string)
      boot_order           = optional(number, 0)
      hot_plug             = optional(bool, false)
    })), {})
  }))

  validation {
    condition     = length(var.instances) > 0
    error_message = "instances must contain at least one worker."
  }

  validation {
    condition = alltrue([
      for name, instance in var.instances :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", name)) && can(cidrhost(instance.address, 0))
    ])
    error_message = "Worker names must be DNS-compatible and addresses must be valid IPv4 CIDRs."
  }

  validation {
    condition = alltrue([
      for instance in values(var.instances) :
      instance.cpu == null || (instance.cpu >= 1 && floor(instance.cpu) == instance.cpu)
    ])
    error_message = "Each per-instance cpu override must be a positive integer."
  }

  validation {
    condition = alltrue([
      for instance in values(var.instances) :
      instance.memory == null || can(regex("^[0-9]+(\\.[0-9]+)?(Ei|Pi|Ti|Gi|Mi|Ki|E|P|T|G|M|K)?$", instance.memory))
    ])
    error_message = "Each per-instance memory override must be a Kubernetes quantity such as 4Gi or 4096Mi."
  }

  validation {
    condition     = length(distinct([for instance in values(var.instances) : instance.address])) == length(var.instances)
    error_message = "Every worker must have a unique static address."
  }

  validation {
    condition = length(flatten([
      for instance in values(var.instances) : [
        for disk in values(instance.persistent_disks) : disk.existing_volume_name
      ]
      ])) == length(distinct(flatten([
        for instance in values(var.instances) : [
          for disk in values(instance.persistent_disks) : disk.existing_volume_name
        ]
    ])))
    error_message = "A persistent volume may be attached to only one worker in the group."
  }
}

variable "root_image" {
  description = "Harvester image ID used for worker root disks."
  type        = string
}

variable "namespace" {
  description = "Harvester namespace in which to create workers and their LoadBalancer."
  type        = string
  default     = "default"
}

variable "cpu" {
  description = "Number of virtual CPU cores per worker."
  type        = number
  default     = 2
}

variable "memory" {
  description = "Memory allocated to each worker."
  type        = string
  default     = "4Gi"
}

variable "root_disk_size" {
  description = "Root disk size of each worker."
  type        = string
  default     = "40Gi"
}

variable "network" {
  description = "Shared cluster VLAN configuration for all workers."
  type = object({
    name        = string
    gateway     = string
    dns_servers = optional(list(string), ["1.1.1.1", "8.8.8.8"])
  })
}

variable "load_balancer" {
  description = "Management-facing Harvester LoadBalancer for the worker HTTP backends."
  type = object({
    address                  = string
    subnet                   = string
    gateway                  = string
    harvester_pod_cidr       = string
    management_guest_gateway = optional(string, "10.0.2.1")
    name                     = optional(string, "k8s-workers")
    pool_name                = optional(string, "k8s-workers")
    listener_port            = optional(number, 80)
    backend_port             = optional(number, 80)
  })

  validation {
    condition = alltrue([
      can(cidrnetmask("${var.load_balancer.address}/32")),
      can(cidrnetmask(var.load_balancer.subnet)),
      can(cidrnetmask("${var.load_balancer.gateway}/32")),
      can(cidrnetmask(var.load_balancer.harvester_pod_cidr)),
      can(cidrnetmask("${var.load_balancer.management_guest_gateway}/32")),
    ])
    error_message = "LoadBalancer addresses and CIDRs must be valid IPv4 values."
  }
}

variable "cluster_generation" {
  description = "Opaque control-plane bootstrap digest; changes rebuild every worker against the new cluster CA."
  type        = string
}

variable "join_command" {
  description = "Sensitive kubeadm join command emitted by the control-plane module."
  type        = string
  sensitive   = true
}

variable "ssh_authorized_keys" {
  description = "SSH public keys authorized for the ubuntu user."
  type        = list(string)
  default     = []
}

variable "kubernetes_version" {
  description = "Kubernetes package repository minor version."
  type        = string
  default     = "1.31"
}
