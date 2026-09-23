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