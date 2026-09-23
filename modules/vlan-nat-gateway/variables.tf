variable "network_id" {
  description = "Target VLAN NAD as namespace/name."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?/[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.network_id))
    error_message = "network_id must be namespace/name using DNS-1123 labels."
  }
}
variable "cidr" {
  description = "IPv4 VLAN subnet."
  type        = string
  validation {
    condition     = can(cidrnetmask(var.cidr)) && can(cidrhost(var.cidr, 1))
    error_message = "cidr must be a valid IPv4 subnet with at least one usable host."
  }
}
variable "gateway_offset" {
  description = "Gateway host offset inside cidr."
  type        = number
  default     = 1
  validation {
    condition     = var.gateway_offset > 0 && floor(var.gateway_offset) == var.gateway_offset
    error_message = "gateway_offset must be a positive integer."
  }
}
variable "image" {
  description = "Pinned gateway image containing ip, iptables, nft, sysctl, and conntrack."
  type        = string
  default     = "docker.io/nicolaka/netshoot@sha256:a20c2531bf35436ed3766cd6cfe89d352b050ccc4d7005ce6400adf97503da1b"
}
variable "name_prefix" {
  type    = string
  default = null
}
variable "node_selector" {
  description = "Required node with VLAN uplink."
  type        = map(string)
  validation {
    condition     = length(var.node_selector) > 0
    error_message = "node_selector is required."
  }
}
variable "labels" {
  type    = map(string)
  default = {}
}
