variable "name" {
  description = "Name of the Longhorn BackupTarget. Volumes must reference this name through spec.backupTargetName."
  type        = string
  default     = "default"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.name)) && length(var.name) <= 63
    error_message = "name must be a valid Kubernetes DNS label with at most 63 characters."
  }
}

variable "namespace" {
  description = "Namespace containing the Longhorn CRDs and credential Secret."
  type        = string
  default     = "longhorn-system"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.namespace)) && length(var.namespace) <= 63
    error_message = "namespace must be a valid Kubernetes DNS label with at most 63 characters."
  }
}

variable "bucket" {
  description = "S3-compatible bucket name. The bucket must already exist."
  type        = string

  validation {
    condition = (
      length(var.bucket) >= 3 &&
      length(var.bucket) <= 63 &&
      can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.bucket)) &&
      !strcontains(var.bucket, "..")
    )
    error_message = "bucket must be a valid S3 bucket name between 3 and 63 characters."
  }
}

variable "region" {
  description = "S3-compatible region used in the Longhorn backup target URL. Use the provider-required value, commonly us-east-1."
  type        = string

  validation {
    condition     = trimspace(var.region) == var.region && var.region != "" && !strcontains(var.region, "@") && !strcontains(var.region, "/")
    error_message = "region must be non-empty and must not contain whitespace, @, or /."
  }
}

variable "credential_secret_name" {
  description = "Existing Secret in namespace containing AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and AWS_ENDPOINTS. Secret contents are intentionally not managed by this module."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$", var.credential_secret_name)) && length(var.credential_secret_name) <= 253
    error_message = "credential_secret_name must be a valid Kubernetes DNS subdomain."
  }
}

variable "poll_interval" {
  description = "How often Longhorn synchronizes metadata from the remote backup target."
  type        = string
  default     = "5m0s"

  validation {
    condition     = can(regex("^[1-9][0-9]*(s|m|h)([0-9]+(s|m))?$", var.poll_interval))
    error_message = "poll_interval must be a positive Go duration such as 30s, 5m0s, or 1h0m."
  }
}

variable "recurring_jobs" {
  description = "Recurring Longhorn backup jobs keyed by Kubernetes resource name."
  type = map(object({
    cron                 = string
    retain               = number
    concurrency          = optional(number, 1)
    groups               = set(string)
    labels               = optional(map(string), {})
    full_backup_interval = optional(number, 0)
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, job in var.recurring_jobs :
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", name)) &&
      length(name) <= 63 &&
      trimspace(job.cron) == job.cron &&
      length(split(" ", job.cron)) == 5 &&
      job.retain >= 1 && floor(job.retain) == job.retain &&
      job.concurrency >= 1 && floor(job.concurrency) == job.concurrency &&
      length(job.groups) > 0 &&
      alltrue([for group in job.groups : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", group)) && length(group) <= 63]) &&
      job.full_backup_interval >= 0 && floor(job.full_backup_interval) == job.full_backup_interval
    ])
    error_message = "Each recurring job needs a valid name, five-field cron, positive integer retain/concurrency, at least one valid group, and a non-negative integer full_backup_interval."
  }
}

variable "volume_groups" {
  description = "Longhorn volume names mapped to recurring-job groups. Use stable input from the protected volume's bound Harvester PV, not a guest Kubernetes PV."
  type        = map(set(string))
  default     = {}

  validation {
    condition = alltrue(flatten([
      for volume, groups in var.volume_groups : concat(
        [trimspace(volume) == volume && volume != ""],
        [length(groups) > 0],
        [for group in groups : can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", group)) && length(group) <= 63]
      )
    ]))
    error_message = "Each volume name must be non-empty and map to at least one valid recurring-job group."
  }

  validation {
    condition = length(setsubtract(
      toset(flatten([for groups in values(var.volume_groups) : tolist(groups)])),
      toset(flatten([for job in values(var.recurring_jobs) : tolist(job.groups)]))
    )) == 0
    error_message = "Every volume group must be declared by at least one recurring job."
  }
}
