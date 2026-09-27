output "cronjob_name" {
  description = "Name of the cluster-wide manifest backup CronJob."
  value       = kubernetes_cron_job_v1.backup.metadata[0].name
}

output "restore_job_name" {
  description = "Name of the suspended manual restore Job."
  value       = kubernetes_cron_job_v1.restore.metadata[0].name
}

output "s3_secret_name" {
  description = "Name of the Kubernetes Secret that stores S3 credentials."
  value       = kubernetes_secret_v1.s3.metadata[0].name
}
