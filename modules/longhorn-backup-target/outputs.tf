output "name" {
  description = "Name of the managed Longhorn BackupTarget."
  value       = kubernetes_manifest.backup_target.object.metadata.name
}

output "namespace" {
  description = "Namespace containing the managed Longhorn backup resources."
  value       = kubernetes_manifest.backup_target.object.metadata.namespace
}

output "backup_target_url" {
  description = "Configured S3-compatible Longhorn backup target URL."
  value       = local.backup_target_url
}

output "recurring_job_names" {
  description = "Names of the managed Longhorn RecurringJobs."
  value       = sort(keys(kubernetes_manifest.recurring_job))
}

output "managed_volume_names" {
  description = "Longhorn volume names assigned to recurring-job groups."
  value       = sort(keys(kubernetes_labels.volume_groups))
}
