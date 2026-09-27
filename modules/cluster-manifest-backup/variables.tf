variable "namespace" {
  description = "Existing namespace that holds the backup CronJob, its ServiceAccount, and its S3 credential Secret."
  type        = string
  default     = "kube-system"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.namespace))
    error_message = "namespace must be a valid Kubernetes DNS-1123 label."
  }
}

variable "name" {
  description = "Name shared by every object this module creates. Changing it creates a different CronJob rather than renaming the existing one."
  type        = string
  default     = "cluster-manifest-backup"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,45}[a-z0-9])?$", var.name))
    error_message = "name must be a DNS-1123 label of at most 47 characters so derived object names stay valid."
  }
}

variable "schedule" {
  description = "Cron schedule for the backup CronJob. One CronJob exists per cluster, so the cadence is independent of how many control-plane nodes run."
  type        = string
  default     = "*/5 * * * *"

  validation {
    condition     = length(split(" ", trimspace(var.schedule))) == 5
    error_message = "schedule must be a five-field cron expression such as */5 * * * *."
  }
}

variable "image" {
  description = "Backup image. It must already contain kubectl, the MinIO client (mc), and tar, because a job that runs every few minutes must not download tooling on each run."
  type        = string

  validation {
    condition     = trimspace(var.image) != ""
    error_message = "image must not be empty."
  }
}

variable "s3" {
  description = "S3-compatible backup destination. endpoint must include its scheme so TLS is explicit rather than guessed."
  type = object({
    endpoint   = string
    bucket     = string
    access_key = string
    secret_key = string
    region     = optional(string, "us-east-1")
    prefix     = optional(string, "cluster-manifests")
  })
  sensitive = true

  validation {
    condition     = can(regex("^https?://", var.s3.endpoint))
    error_message = "s3.endpoint must start with http:// or https://."
  }

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9.]{1,61}[a-z0-9])$", var.s3.bucket))
    error_message = "s3.bucket must be a valid S3 bucket name of 3-63 lowercase characters."
  }

  validation {
    condition     = trimspace(var.s3.access_key) != "" && trimspace(var.s3.secret_key) != ""
    error_message = "s3.access_key and s3.secret_key must not be empty."
  }

  validation {
    condition     = !startswith(var.s3.prefix, "/") && !endswith(var.s3.prefix, "/")
    error_message = "s3.prefix must not start or end with a slash."
  }
}

variable "retain" {
  description = "Days of backups to keep in the bucket. Each run prunes objects older than this, so the bucket does not grow without bound at a five-minute cadence."
  type        = number
  default     = 7

  validation {
    condition     = var.retain >= 1 && floor(var.retain) == var.retain
    error_message = "retain must be a positive integer number of days."
  }
}

variable "resources" {
  description = "Container resource requests and limits. These exist so the backup pod is not BestEffort and evicted first under node pressure."
  type = object({
    requests_cpu    = optional(string, "50m")
    requests_memory = optional(string, "128Mi")
    limits_cpu      = optional(string, "500m")
    limits_memory   = optional(string, "512Mi")
  })
  default = {}
}

variable "labels" {
  description = "Extra labels merged beneath module-managed labels."
  type        = map(string)
  default     = {}
}
