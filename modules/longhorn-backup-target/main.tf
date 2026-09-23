locals {
  backup_target_url = "s3://${var.bucket}@${var.region}/"

  volume_group_labels = {
    for volume, groups in var.volume_groups : volume => {
      for group in groups : "recurring-job-group.longhorn.io/${group}" => "enabled"
    }
  }
}

resource "kubernetes_manifest" "backup_target" {
  manifest = {
    apiVersion = "longhorn.io/v1beta2"
    kind       = "BackupTarget"
    metadata = {
      name      = var.name
      namespace = var.namespace
    }
    spec = {
      backupTargetURL  = local.backup_target_url
      credentialSecret = var.credential_secret_name
      pollInterval     = var.poll_interval
    }
  }
}

resource "kubernetes_manifest" "recurring_job" {
  for_each = var.recurring_jobs

  manifest = {
    apiVersion = "longhorn.io/v1beta2"
    kind       = "RecurringJob"
    metadata = {
      name      = each.key
      namespace = var.namespace
    }
    spec = {
      name        = each.key
      cron        = each.value.cron
      task        = "backup"
      retain      = each.value.retain
      concurrency = each.value.concurrency
      groups      = sort(tolist(each.value.groups))
      labels      = each.value.labels
      parameters = each.value.full_backup_interval > 0 ? {
        "full-backup-interval" = tostring(each.value.full_backup_interval)
      } : {}
    }
  }

  depends_on = [kubernetes_manifest.backup_target]
}

resource "kubernetes_labels" "volume_groups" {
  for_each = local.volume_group_labels

  api_version = "longhorn.io/v1beta2"
  kind        = "Volume"

  metadata {
    name      = each.key
    namespace = var.namespace
  }

  labels = each.value

  depends_on = [kubernetes_manifest.recurring_job]
}
