variable "root_image" {
  description = "Harvester image ID used for the Kubernetes worker root disk."
  type        = string
}

variable "namespace" {
  description = "Harvester namespace in which to create the worker VM."
  type        = string
  default     = "default"
}

variable "name_prefix" {
  description = "Name prefix for the Kubernetes worker VM."
  type        = string
  default     = "k8s-worker"
}

variable "cpu" {
  description = "Number of virtual CPU cores."
  type        = number
  default     = 2
}

variable "memory" {
  description = "Memory allocated to the worker VM."
  type        = string
  default     = "4Gi"
}

variable "root_disk_size" {
  description = "Root disk size of the worker VM."
  type        = string
  default     = "40Gi"
}

variable "network" {
  description = "Static VLAN network configuration for the worker VM."
  type = object({
    name        = string
    address     = string
    gateway     = string
    dns_servers = optional(list(string), ["1.1.1.1", "8.8.8.8"])
  })

  validation {
    condition     = can(cidrhost(var.network.address, 0))
    error_message = "network.address must be a valid IPv4 CIDR address."
  }

  validation {
    condition = try(
      cidrsubnet(var.network.address, 0, 0) == cidrsubnet("${var.network.gateway}/${split("/", var.network.address)[1]}", 0, 0),
      false
    )
    error_message = "network.gateway must belong to the same subnet as network.address."
  }
}

variable "cluster_generation" {
  description = "Opaque control-plane bootstrap digest. A change forces this worker to be rebuilt and rejoin the new cluster CA."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.cluster_generation))
    error_message = "cluster_generation must be a sha256 hex digest."
  }
}

variable "join_command" {
  description = "Sensitive kubeadm join command emitted by the control-plane module."
  type        = string
  sensitive   = true

  validation {
    condition     = startswith(var.join_command, "kubeadm join ")
    error_message = "join_command must start with 'kubeadm join '."
  }
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
