mock_provider "kubernetes" {}

variables {
  image = "registry.example.com/cluster-manifest-backup:v1"

  s3 = {
    endpoint   = "https://minio.example.com"
    bucket     = "cluster-backups"
    access_key = "test-access-key"
    secret_key = "test-secret-key"
  }
}

run "single_cluster_wide_cronjob" {
  command = plan

  assert {
    condition     = kubernetes_cron_job_v1.backup.spec[0].schedule == "*/5 * * * *"
    error_message = "The backup must run every 5 minutes."
  }

  assert {
    condition     = kubernetes_cron_job_v1.backup.spec[0].concurrency_policy == "Forbid"
    error_message = "A slow run must never overlap with the next scheduled run."
  }

  assert {
    condition     = kubernetes_cron_job_v1.restore.spec[0].suspend == true
    error_message = "Restore must stay manual: its CronJob template must stay suspended so no schedule, cluster start, or node start can trigger it."
  }

  assert {
    condition     = kubernetes_cluster_role_v1.backup.rule[0].verbs == tolist(["get", "list"])
    error_message = "The backup ServiceAccount must be read-only."
  }

  assert {
    condition     = strcontains(kubernetes_config_map_v1.scripts.data["backup.sh"], "kubectl api-resources")
    error_message = "The backup must enumerate API resources rather than rely on kubectl get all, which omits most types."
  }

  assert {
    condition     = !strcontains(kubernetes_config_map_v1.scripts.data["backup.sh"], "/etc/kubernetes/manifests")
    error_message = "The backup must read through the API server so it does not depend on one control-plane node's local files."
  }
}

run "endpoint_without_scheme_rejected" {
  command = plan

  variables {
    s3 = {
      endpoint   = "minio.example.com"
      bucket     = "cluster-backups"
      access_key = "test-access-key"
      secret_key = "test-secret-key"
    }
  }

  expect_failures = [var.s3]
}

run "prefix_with_trailing_slash_rejected" {
  command = plan

  variables {
    s3 = {
      endpoint   = "https://minio.example.com"
      bucket     = "cluster-backups"
      access_key = "test-access-key"
      secret_key = "test-secret-key"
      prefix     = "cluster-manifests/"
    }
  }

  expect_failures = [var.s3]
}

run "invalid_schedule_rejected" {
  command = plan

  variables {
    schedule = "*/5 * * *"
  }

  expect_failures = [var.schedule]
}
