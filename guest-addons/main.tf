module "cluster_manifest_backup" {
  source = "../modules/cluster-manifest-backup"

  image = var.manifest_backup_image
  s3    = var.manifest_backup_s3
}

output "manifest_backup_cronjob_name" {
  description = "Name of the guest-cluster CronJob that exports API resources every five minutes."
  value       = module.cluster_manifest_backup.cronjob_name
}

output "manifest_restore_job_name" {
  description = "Name of the suspended CronJob template used to create explicit manual restore Jobs."
  value       = module.cluster_manifest_backup.restore_job_name
}
