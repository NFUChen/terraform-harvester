variable "namespace" {
  description = "Namespace holding every NetworkAttachmentDefinition in this module call. VM network_interface.network_name references are namespace-qualified."
  type        = string
  default     = "harvester-public"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a valid Kubernetes DNS-1123 label."
  }
}

variable "cluster_network_name" {
  description = "ClusterNetwork backing every network in this module call. It must already exist and be Ready; this module does not manage ClusterNetwork or VLANConfig."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.cluster_network_name))
    error_message = "cluster_network_name must be a valid Kubernetes DNS-1123 label."
  }
}

variable "labels" {
  description = "Labels applied to every network, merged beneath module-managed labels."
  type        = map(string)
  default     = {}

  validation {
    condition     = !contains(keys(var.labels), "network.harvesterhci.io/clusternetwork")
    error_message = "network.harvesterhci.io/clusternetwork is managed by the Harvester network controller and must not be set through global labels."
  }
}

variable "tags" {
  description = "Harvester tags applied to every network."
  type        = map(string)
  default     = {}
}

variable "timeouts" {
  description = "Terraform operation timeouts. These do not extend the provider's separate one-minute ClusterNetwork readiness wait."
  type = object({
    create = optional(string, "5m")
    read   = optional(string, "2m")
    update = optional(string, "5m")
    delete = optional(string, "10m")
  })
  default = {}
}

variable "networks" {
  description = "Networks to manage, keyed by the exact NAD name. The key is the Kubernetes object identity referenced by VMs, so changing a key means creating a different network rather than renaming one."
  type = map(object({
    vlan_id     = number
    description = optional(string)
    labels      = optional(map(string), {})
    tags        = optional(map(string), {})
    route = optional(object({
      mode           = optional(string, "auto")
      cidr           = optional(string)
      gateway        = optional(string)
      dhcp_server_ip = optional(string)
    }), {})
  }))

  validation {
    condition     = length(var.networks) > 0
    error_message = "networks must declare at least one network."
  }

  validation {
    condition = alltrue([
      for name in keys(var.networks) :
      can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$", name)) && length(name) <= 253
    ])
    error_message = "Every networks key must be a valid DNS-1123 subdomain NAD name of at most 253 characters."
  }

  validation {
    condition = alltrue([
      for network in values(var.networks) :
      network.vlan_id >= 0 && network.vlan_id <= 4094 && floor(network.vlan_id) == network.vlan_id
    ])
    error_message = "Every vlan_id must be an integer between 0 and 4094."
  }

  validation {
    condition = alltrue([
      for network in values(var.networks) :
      contains(["auto", "manual"], network.route.mode)
    ])
    error_message = "route.mode must be auto or manual."
  }

  validation {
    condition = alltrue([
      for network in values(var.networks) :
      network.route.mode != "auto" || (network.route.cidr == null && network.route.gateway == null)
    ])
    error_message = "route.mode = auto rejects route.cidr and route.gateway; the Harvester controller derives them."
  }

  validation {
    condition = alltrue([
      for network in values(var.networks) :
      network.route.mode != "manual" || (network.route.cidr != null && network.route.gateway != null)
    ])
    error_message = "route.mode = manual requires both route.cidr and route.gateway."
  }

  validation {
    condition = alltrue([
      for network in values(var.networks) :
      network.route.mode != "manual" || network.route.dhcp_server_ip == null
    ])
    error_message = "route.dhcp_server_ip conflicts with manual route.cidr/route.gateway."
  }

  validation {
    condition = alltrue([
      for network in values(var.networks) :
      network.route.cidr == null || can(cidrnetmask(network.route.cidr))
    ])
    error_message = "route.cidr must be a valid IPv4 CIDR such as 172.16.100.0/24."
  }

  validation {
    condition = alltrue([
      for network in values(var.networks) :
      network.route.gateway == null || can(cidrnetmask("${network.route.gateway}/32"))
    ])
    error_message = "route.gateway must be a valid IPv4 address."
  }

  validation {
    condition = alltrue([
      for network in values(var.networks) :
      network.route.cidr == null || network.route.gateway == null || try(
        cidrsubnet("${network.route.gateway}/${split("/", network.route.cidr)[1]}", 0, 0) ==
        cidrsubnet(network.route.cidr, 0, 0),
        false
      )
    ])
    error_message = "route.gateway must belong to route.cidr."
  }

  validation {
    condition = alltrue([
      for network in values(var.networks) :
      network.route.dhcp_server_ip == null || can(cidrnetmask("${network.route.dhcp_server_ip}/32"))
    ])
    error_message = "route.dhcp_server_ip must be a valid IPv4 address."
  }

  validation {
    condition = alltrue([
      for network in values(var.networks) :
      !contains(keys(network.labels), "network.harvesterhci.io/clusternetwork")
    ])
    error_message = "network.harvesterhci.io/clusternetwork is managed by the Harvester network controller and must not be set by callers."
  }
}
