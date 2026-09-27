variable "kubeconfig" {
  description = "Path to the guest cluster kubeconfig exported by the vm/ stack."
  type        = string
  default     = "../vm/kubeconfig"
}

variable "kubecontext" {
  description = "Optional context inside the guest kubeconfig."
  type        = string
  default     = null
  nullable    = true
}

variable "manifest_backup_image" {
  description = "Image containing kubectl, mc, and tar used by the backup and restore jobs."
  type        = string
}

variable "manifest_backup_s3" {
  description = "S3-compatible destination for cluster manifest backups."
  type = object({
    endpoint   = string
    bucket     = string
    access_key = string
    secret_key = string
    region     = optional(string, "us-east-1")
    prefix     = optional(string, "cluster-manifests")
  })
  sensitive = true
}
