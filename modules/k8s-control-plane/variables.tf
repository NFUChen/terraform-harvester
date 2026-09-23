variable "root_image" {
  description = "Harvester image ID used for the Kubernetes control-plane root disk."
  type        = string
}

variable "namespace" {
  description = "Harvester namespace in which to create the control-plane VM."
  type        = string
  default     = "default"
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

variable "load_balancer" {
  description = "Management-facing Harvester LoadBalancer. address is a caller-owned fixed IP; subnet includes its prefix length."
  type = object({
    address                  = string
    subnet                   = string
    gateway                  = string
    harvester_pod_cidr       = string
    management_guest_gateway = optional(string, "10.0.2.1")
    name                     = optional(string, "guest-k8s-control-plane")
    listener_port            = optional(number, 6443)
    pool_name                = optional(string, "guest-k8s-control-plane")
  })

  validation {
    condition     = var.load_balancer.listener_port >= 1 && var.load_balancer.listener_port <= 65535 && floor(var.load_balancer.listener_port) == var.load_balancer.listener_port
    error_message = "load_balancer.listener_port must be an integer between 1 and 65535."
  }

  validation {
    condition = alltrue([
      can(cidrnetmask("${var.load_balancer.address}/32")),
      can(cidrnetmask(var.load_balancer.subnet)),
      can(cidrnetmask("${var.load_balancer.gateway}/32")),
      can(cidrnetmask(var.load_balancer.harvester_pod_cidr)),
      can(cidrnetmask("${var.load_balancer.management_guest_gateway}/32")),
    ])
    error_message = "load_balancer address, subnet, and gateway must be valid IPv4 values."
  }

  validation {
    condition = alltrue([
      for address in [var.load_balancer.address, var.load_balancer.gateway] :
      try(cidrsubnet("${address}/${split("/", var.load_balancer.subnet)[1]}", 0, 0) == cidrsubnet(var.load_balancer.subnet, 0, 0), false)
    ])
    error_message = "load_balancer address and gateway must belong to load_balancer.subnet."
  }
}

variable "kubeconfig_export" {
  description = "Local kubeconfig export over the LoadBalancer SSH listener. Paths are evaluated on the machine running Terraform."
  type = object({
    private_key_path = string
    output_path      = string
    enabled          = optional(bool, true)
    ssh_user         = optional(string, "ubuntu")
    ssh_port         = optional(number, 22)
  })

  validation {
    condition     = var.kubeconfig_export.ssh_port >= 1 && var.kubeconfig_export.ssh_port <= 65535 && floor(var.kubeconfig_export.ssh_port) == var.kubeconfig_export.ssh_port
    error_message = "kubeconfig_export.ssh_port must be an integer between 1 and 65535."
  }

  validation {
    condition     = length(trimspace(var.kubeconfig_export.private_key_path)) > 0 && length(trimspace(var.kubeconfig_export.output_path)) > 0
    error_message = "kubeconfig_export paths must not be empty."
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

variable "cni" {
  description = "Flannel CNI release applied after kubeadm init. The manifest is verified against manifest_sha256 before it is applied."
  type = object({
    version         = optional(string, "v0.28.9")
    manifest_sha256 = optional(string, "1c06a15a771009c263bdb1f51c928af46f7606fe969f3963652167938d536aaa")
  })
  default = {}

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.cni.version))
    error_message = "cni.version must be a pinned Flannel release such as v0.28.9."
  }

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.cni.manifest_sha256))
    error_message = "cni.manifest_sha256 must be the hex sha256 of the pinned kube-flannel.yml."
  }
}

variable "metrics_server" {
  description = "metrics-server release applied to the cluster after bootstrap. Applied over the LoadBalancer SSH listener, so it does not touch cloud-init and never forces the control-plane VM to be rebuilt."
  type = object({
    enabled              = optional(bool, true)
    version              = optional(string, "v0.7.2")
    manifest_sha256      = optional(string, "f103539a54ed72efe66616afc74a8bfaed651703cb3918797599046af5617441")
    kubelet_insecure_tls = optional(bool, true)
  })
  default = {}

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.metrics_server.version))
    error_message = "metrics_server.version must be a pinned metrics-server release such as v0.7.2."
  }

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.metrics_server.manifest_sha256))
    error_message = "metrics_server.manifest_sha256 must be the hex sha256 of the pinned components.yaml."
  }
}

variable "pod_network_cidr" {
  description = "Pod network CIDR passed to kubeadm init."
  type        = string
  default     = "10.244.0.0/16"
}