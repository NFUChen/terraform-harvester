variable "network_id" {
  description = "Target VLAN network as namespace/name, exactly the value exposed by protected-network's ids output. The DHCP pod is deployed into that same namespace so Multus namespace isolation cannot block the attachment."
  type        = string

  validation {
    condition = can(regex(
      "^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?/[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$",
      var.network_id,
    )) && (var.name_prefix != null || length(split("/", var.network_id)[1]) <= 58)
    error_message = "network_id must be namespace/name with DNS-1123 labels; when name_prefix is omitted, the network name must be at most 58 characters so the derived -dhcp resource name remains valid."
  }
}

variable "cidr" {
  description = "IPv4 subnet served on this VLAN, for example 172.16.110.0/24. All addresses are derived from this CIDR by host offset so a typo cannot silently place DHCP on a different subnet."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.cidr))
    error_message = "cidr must be a valid IPv4 CIDR such as 172.16.110.0/24."
  }

  validation {
    condition     = can(cidrhost(var.cidr, 2))
    error_message = "cidr is too small to host a gateway and a DHCP server; use at least a /30."
  }
}

variable "pool_start_offset" {
  description = "First leasable address as a host offset inside cidr. Offsets are used instead of literal IPs so the module can verify ordering and subnet membership, which Terraform cannot do reliably by comparing IP strings."
  type        = number

  validation {
    condition     = var.pool_start_offset > 0 && floor(var.pool_start_offset) == var.pool_start_offset
    error_message = "pool_start_offset must be a positive integer."
  }

  validation {
    condition     = can(cidrhost(var.cidr, var.pool_start_offset))
    error_message = "pool_start_offset falls outside cidr."
  }

  validation {
    condition     = var.pool_start_offset > var.gateway_offset && var.pool_start_offset > var.server_offset
    error_message = "The DHCP pool must start after both gateway_offset and server_offset so dnsmasq cannot lease away the gateway or its own address."
  }
}

variable "pool_end_offset" {
  description = "Last leasable address as a host offset inside cidr."
  type        = number

  validation {
    condition     = var.pool_end_offset > 0 && floor(var.pool_end_offset) == var.pool_end_offset
    error_message = "pool_end_offset must be a positive integer."
  }

  validation {
    condition     = can(cidrhost(var.cidr, var.pool_end_offset))
    error_message = "pool_end_offset falls outside cidr."
  }

  validation {
    condition     = try(cidrhost(var.cidr, var.pool_end_offset) != cidrhost(var.cidr, -1), false)
    error_message = "pool_end_offset must not resolve to the subnet broadcast address."
  }

  validation {
    condition     = var.pool_end_offset >= var.pool_start_offset
    error_message = "pool_end_offset must be greater than or equal to pool_start_offset."
  }
}

variable "gateway_offset" {
  description = "Host offset of the VLAN gateway. This is advertised to clients; the module does not create or verify the gateway."
  type        = number
  default     = 1

  validation {
    condition     = var.gateway_offset > 0 && floor(var.gateway_offset) == var.gateway_offset
    error_message = "gateway_offset must be a positive integer."
  }
}

variable "server_offset" {
  description = "Host offset the dnsmasq pod binds as its static address on the VLAN interface."
  type        = number
  default     = 2

  validation {
    condition     = var.server_offset > 0 && floor(var.server_offset) == var.server_offset
    error_message = "server_offset must be a positive integer."
  }
}

variable "dns_servers" {
  description = "DNS servers advertised to DHCP clients. Defaults to the VLAN gateway, which assumes the gateway forwards DNS."
  type        = list(string)
  default     = null
  nullable    = true

  validation {
    condition     = var.dns_servers == null || length(var.dns_servers) > 0
    error_message = "dns_servers must be null to use the gateway, or a non-empty list."
  }

  validation {
    condition = var.dns_servers == null || alltrue([
      for server in var.dns_servers : can(cidrnetmask("${server}/32"))
    ])
    error_message = "every dns_servers entry must be a valid IPv4 address."
  }
}

variable "lease_time" {
  description = "dnsmasq lease time, for example 12h, 30m, or infinite. Zero-duration and unbounded numeric strings are rejected."
  type        = string
  default     = "12h"

  validation {
    condition     = var.lease_time == "infinite" || can(regex("^[1-9][0-9]{0,5}[smhd]$", var.lease_time))
    error_message = "lease_time must be infinite or a non-zero 1-6 digit number followed by s, m, h, or d."
  }
}

variable "domain" {
  description = "Optional single DNS domain suffix advertised to clients."
  type        = string
  default     = null

  validation {
    condition = var.domain == null || (
      can(regex("^[A-Za-z0-9]([-A-Za-z0-9]{0,61}[A-Za-z0-9])?(\\.[A-Za-z0-9]([-A-Za-z0-9]{0,61}[A-Za-z0-9])?)*$", var.domain)) &&
      length(var.domain) <= 253
    )
    error_message = "domain must be one DNS-compatible suffix without spaces, commas, newlines, leading/trailing dots, or labels longer than 63 characters."
  }
}

variable "image" {
  description = "dnsmasq container image. The default is pinned by immutable digest and was verified to contain dnsmasq 2.80, BusyBox ip, and /bin/sh on amd64. Production should mirror and scan this digest in an internal registry."
  type        = string
  default     = "docker.io/jpillora/dnsmasq@sha256:34132cc95b1b8c124d2402b0da53995e68d2d46b8d0020d63cac9ecccb0e8008"

  validation {
    condition     = trimspace(var.image) != ""
    error_message = "image must not be empty."
  }
}

variable "name_prefix" {
  description = "Name prefix for the ConfigMap and Deployment. Defaults to the network name."
  type        = string
  default     = null

  validation {
    condition     = var.name_prefix == null || (can(regex("^[a-z0-9]([-a-z0-9]{0,56}[a-z0-9])?$", var.name_prefix)) && length(var.name_prefix) <= 58)
    error_message = "name_prefix must be a DNS-1123 label of at most 58 characters."
  }
}

variable "labels" {
  description = "Extra labels merged beneath module-managed labels."
  type        = map(string)
  default     = {}
}

variable "node_selector" {
  description = "Required node selector for the DHCP pod. The VLAN bridge is per-node; pin the server to a node whose VLANConfig/uplink and physical switch trunk carry this VLAN."
  type        = map(string)

  validation {
    condition     = length(var.node_selector) > 0
    error_message = "node_selector is required; an unpinned DHCP server may reschedule onto a node without the VLAN uplink."
  }
}

variable "resources" {
  description = "Container resource requests and limits. dnsmasq is tiny; these defaults exist so the pod is not BestEffort and evicted first under node pressure."
  type = object({
    requests_cpu    = optional(string, "10m")
    requests_memory = optional(string, "32Mi")
    limits_cpu      = optional(string, "200m")
    limits_memory   = optional(string, "128Mi")
  })
  default = {}
}
