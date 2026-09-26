variable "name" {
  description = "Base name shared by the GitHub Actions runner VMs and runner agents. When more than one registration token is supplied, each runner is suffixed with a two-digit index, for example \"github-actions-runner-01\"."
  type        = string
  default     = "github-actions-runner"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name)) && length(var.name) <= 60
    error_message = "name must be a lowercase DNS-compatible name no longer than 60 characters (room is reserved for a runner index suffix)."
  }
}

variable "namespace" {
  description = "Harvester namespace in which to create the runner VM."
  type        = string
  default     = "default"
}

variable "root_image" {
  description = "Harvester Ubuntu image ID used for the runner root disk."
  type        = string
}

variable "github_url" {
  description = "Repository or organization URL where the runner is registered, for example https://github.com/acme/widgets or https://github.com/acme."
  type        = string

  validation {
    condition     = can(regex("^https://github\\.com/[^/]+(/[^/]+)?/?$", var.github_url))
    error_message = "github_url must be an https://github.com organization or repository URL."
  }
}

variable "registration_tokens" {
  description = "Comma-separated short-lived GitHub Actions runner registration tokens. One runner is created per token; values are stored in Terraform state and cloud-init data."
  type        = string
  sensitive   = true

  validation {
    condition = (
      length(trimspace(var.registration_tokens)) > 0 &&
      alltrue([for token in split(",", var.registration_tokens) : length(trimspace(token)) > 0])
    )
    error_message = "registration_tokens must contain one or more non-empty comma-separated tokens."
  }
}

variable "cpu" {
  description = "Number of virtual CPU cores assigned to each runner."
  type        = number
  default     = 2
}

variable "memory" {
  description = "Memory assigned to each runner as a Kubernetes quantity."
  type        = string
  default     = "4Gi"
}

variable "root_disk_size" {
  description = "Root disk size of the runner VM."
  type        = string
  default     = "80Gi"
}

variable "network" {
  description = "Runner network. Omit name to use Harvester's masquerade management network with DHCP, or provide a VLAN NAD as namespace/name."
  type = object({
    name           = optional(string)
    wait_for_lease = optional(bool, true)
  })
  default = {}
}

variable "ssh_authorized_keys" {
  description = "SSH public keys authorized for the ubuntu user."
  type        = list(string)
  default     = []
}

variable "labels" {
  description = "Additional custom GitHub Actions runner labels."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for label in var.labels : length(trimspace(label)) > 0 && !strcontains(label, ",")])
    error_message = "Runner labels must be non-empty and cannot contain commas."
  }
}

variable "runner_group" {
  description = "Optional existing GitHub Actions runner group name."
  type        = string
  default     = null
  nullable    = true
}

variable "runner_version" {
  description = "Pinned GitHub Actions runner release version without the leading v."
  type        = string
  default     = "2.337.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.runner_version))
    error_message = "runner_version must be a semantic version such as 2.337.0."
  }
}

variable "runner_sha256" {
  description = "SHA-256 checksum for the pinned linux-x64 runner tarball."
  type        = string
  default     = "70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.runner_sha256))
    error_message = "runner_sha256 must be a lowercase 64-character SHA-256 digest."
  }
}

variable "install_docker" {
  description = "Install Docker Engine from Ubuntu packages and allow the runner user to use it."
  type        = bool
  default     = true
}
