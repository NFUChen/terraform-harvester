variable "policy_name" {
  description = "Cluster-scoped ValidatingAdmissionPolicy and binding name."
  type        = string
  default     = "protect-harvester-persistent-volumes"
}

variable "break_glass_usernames" {
  description = "Exact Kubernetes request.userInfo.username values allowed to remove protection or delete protected PVCs. Keep this list minimal and map it to an audited emergency identity, never a normal Terraform service account."
  type        = set(string)

  validation {
    condition     = length(var.break_glass_usernames) > 0 && alltrue([for name in var.break_glass_usernames : trimspace(name) != ""])
    error_message = "At least one non-empty, audited break-glass username is required so protected PVCs can be deliberately decommissioned."
  }

  validation {
    condition = alltrue([
      for name in var.break_glass_usernames : name == trimspace(name)
    ])
    error_message = "break_glass_usernames must not contain leading or trailing whitespace; the CEL comparison is an exact string match and a stray space silently locks out the only decommission path."
  }
}

variable "failure_policy" {
  description = "Fail closes deletion protection when policy evaluation is unavailable."
  type        = string
  default     = "Fail"

  validation {
    condition     = var.failure_policy == "Fail"
    error_message = "This safety module requires failure_policy = Fail."
  }
}
