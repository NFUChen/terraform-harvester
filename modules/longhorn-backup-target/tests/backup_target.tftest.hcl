mock_provider "kubernetes" {}

variables {
  bucket                 = "harvester-longhorn-backups"
  region                 = "us-east-1"
  credential_secret_name = "longhorn-s3-backup-credentials"

  recurring_jobs = {
    postgres-six-hourly = {
      cron                 = "0 */6 * * *"
      retain               = 14
      concurrency          = 1
      groups               = ["postgres-data"]
      labels               = { workload = "postgres" }
      full_backup_interval = 7
    }
  }

  volume_groups = {
    "pvc-example-volume" = ["postgres-data"]
  }
}

run "s3_backup_target_and_schedule" {
  command = plan

  assert {
    condition     = kubernetes_manifest.backup_target.manifest.apiVersion == "longhorn.io/v1beta2" && kubernetes_manifest.backup_target.manifest.kind == "BackupTarget"
    error_message = "The module must manage the Longhorn v1beta2 BackupTarget CRD installed by Harvester."
  }

  assert {
    condition     = kubernetes_manifest.backup_target.manifest.spec.backupTargetURL == "s3://harvester-longhorn-backups@us-east-1/"
    error_message = "The Longhorn S3 backup target URL must be derived from the bucket and region."
  }

  assert {
    condition     = kubernetes_manifest.backup_target.manifest.spec.credentialSecret == "longhorn-s3-backup-credentials"
    error_message = "The BackupTarget must reference the external credential Secret without managing its contents."
  }

  assert {
    condition = (
      kubernetes_manifest.recurring_job["postgres-six-hourly"].manifest.spec.task == "backup" &&
      kubernetes_manifest.recurring_job["postgres-six-hourly"].manifest.spec.cron == "0 */6 * * *" &&
      kubernetes_manifest.recurring_job["postgres-six-hourly"].manifest.spec.retain == 14 &&
      kubernetes_manifest.recurring_job["postgres-six-hourly"].manifest.spec.parameters["full-backup-interval"] == "7"
    )
    error_message = "The recurring job must create six-hourly backups with the configured retention and full-backup interval."
  }

  assert {
    condition     = kubernetes_labels.volume_groups["pvc-example-volume"].labels["recurring-job-group.longhorn.io/postgres-data"] == "enabled"
    error_message = "The protected Longhorn volume must be enrolled in the PostgreSQL recurring-job group."
  }
}

run "undeclared_volume_group_rejected" {
  command = plan

  variables {
    volume_groups = {
      "pvc-example-volume" = ["unknown-group"]
    }
  }

  expect_failures = [var.volume_groups]
}

run "invalid_bucket_rejected" {
  command = plan

  variables {
    bucket = "Invalid_Bucket"
  }

  expect_failures = [var.bucket]
}

run "empty_credential_secret_rejected" {
  command = plan

  variables {
    credential_secret_name = ""
  }

  expect_failures = [var.credential_secret_name]
}

run "invalid_schedule_rejected" {
  command = plan

  variables {
    recurring_jobs = {
      invalid = {
        cron        = "daily"
        retain      = 0
        concurrency = 0
        groups      = []
      }
    }
    volume_groups = {}
  }

  expect_failures = [var.recurring_jobs]
}
