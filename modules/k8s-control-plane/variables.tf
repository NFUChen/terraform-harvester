variable "root_image" {
  description = "Harvester image ID used for the Kubernetes control-plane root disk."
  type        = string
}

variable "namespace" {
  description = "Harvester namespace in which to create the control-plane VM."
  type        = string
  default     = "default"
}

variable "name_prefix" {
  description = "Name prefix for the Kubernetes control-plane VM."
  type        = string
  default     = "k8s-control-plane"
}

variable "cpu" {
  description = "Number of virtual CPU cores."
  type        = number
  default     = 2
}

variable "memory" {
  description = "Memory allocated to the control-plane VM."
  type        = string
  default     = "4Gi"
}

variable "root_disk_size" {
  description = "Root disk size of the control-plane VM."
  type        = string
  default     = "40Gi"
}

variable "network" {
  description = "Static VLAN network configuration for the control-plane VM. address must include its prefix length."
  type = object({
    name        = string
    address     = string
    gateway     = string
    dns_servers = optional(list(string), ["1.1.1.1", "8.8.8.8"])
  })

  validation {
    condition     = can(cidrhost(var.network.address, 0))
    error_message = "network.address must be a valid IPv4 CIDR address such as 172.16.100.10/24."
  }

  validation {
    condition     = can(cidrnetmask("${var.network.gateway}/32"))
    error_message = "network.gateway must be a valid IPv4 address."
  }

  validation {
    condition = try(
      cidrsubnet(var.network.address, 0, 0) == cidrsubnet("${var.network.gateway}/${split("/", var.network.address)[1]}", 0, 0),
      false
    )
    error_message = "network.gateway must belong to the same subnet as network.address."
  }

  validation {
    condition = alltrue([
      for server in var.network.dns_servers : can(cidrnetmask("${server}/32"))
    ])
    error_message = "Every network.dns_servers entry must be a valid IPv4 address."
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

variable "pod_network_cidr" {
  description = "Pod network CIDR passed to kubeadm init."
  type        = string
  default     = "10.244.0.0/16"
}