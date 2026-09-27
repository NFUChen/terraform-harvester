locals {
  labels = merge(var.labels, {
    "app.kubernetes.io/name"       = "cluster-manifest-backup"
    "app.kubernetes.io/instance"   = var.name
    "app.kubernetes.io/managed-by" = "terraform"
  })

  secret_name = "${var.name}-s3"
}

resource "kubernetes_service_account_v1" "backup" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
}

resource "kubernetes_service_account_v1" "restore" {
  metadata {
    name      = "${var.name}-restore"
    namespace = var.namespace
    labels    = local.labels
  }
}

resource "kubernetes_cluster_role_v1" "backup" {
  metadata {
    name   = var.name
    labels = local.labels
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["get", "list"]
  }

  rule {
    non_resource_urls = ["/api", "/apis", "/openapi/*"]
    verbs             = ["get"]
  }
}

resource "kubernetes_cluster_role_v1" "restore" {
  metadata {
    name   = "${var.name}-restore"
    labels = local.labels
  }

  rule {
    api_groups = ["*"]
    resources  = ["*"]
    verbs      = ["get", "list", "create", "update", "patch"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "backup" {
  metadata {
    name   = var.name
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.backup.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.backup.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_cluster_role_binding_v1" "restore" {
  metadata {
    name   = "${var.name}-restore"
    labels = local.labels
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.restore.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.restore.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_secret_v1" "s3" {
  metadata {
    name      = local.secret_name
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    access_key = var.s3.access_key
    secret_key = var.s3.secret_key
  }

  type = "Opaque"
}

resource "kubernetes_config_map_v1" "scripts" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  data = {
    "backup.sh"  = file("${path.module}/backup.sh")
    "restore.sh" = file("${path.module}/restore.sh")
  }
}

resource "kubernetes_cron_job_v1" "backup" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    schedule                      = var.schedule
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3

    job_template {
      metadata {
        labels = local.labels
      }

      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 86400

        template {
          metadata {
            labels = local.labels
          }

          spec {
            service_account_name            = kubernetes_service_account_v1.backup.metadata[0].name
            automount_service_account_token = true
            restart_policy                  = "Never"

            container {
              name    = "backup"
              image   = var.image
              command = ["/bin/sh", "/scripts/backup.sh"]

              env {
                name  = "S3_ENDPOINT"
                value = var.s3.endpoint
              }
              env {
                name  = "S3_BUCKET"
                value = var.s3.bucket
              }
              env {
                name  = "S3_REGION"
                value = var.s3.region
              }
              env {
                name  = "S3_PREFIX"
                value = var.s3.prefix
              }
              env {
                name  = "RETAIN_DAYS"
                value = tostring(var.retain)
              }
              env {
                name = "S3_ACCESS_KEY"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.s3.metadata[0].name
                    key  = "access_key"
                  }
                }
              }
              env {
                name = "S3_SECRET_KEY"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.s3.metadata[0].name
                    key  = "secret_key"
                  }
                }
              }

              resources {
                requests = {
                  cpu    = var.resources.requests_cpu
                  memory = var.resources.requests_memory
                }
                limits = {
                  cpu    = var.resources.limits_cpu
                  memory = var.resources.limits_memory
                }
              }

              security_context {
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
                run_as_non_root            = true
                run_as_user                = 65532

                capabilities {
                  drop = ["ALL"]
                }

                seccomp_profile {
                  type = "RuntimeDefault"
                }
              }

              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }

              volume_mount {
                name       = "tmp"
                mount_path = "/tmp"
              }
            }

            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map_v1.scripts.metadata[0].name
                default_mode = "0555"
              }
            }

            volume {
              name = "tmp"
              empty_dir {}
            }
          }
        }
      }
    }
  }
}

# Restore is a permanently suspended CronJob, never a scheduled or boot-time
# action. An operator recovers explicitly with:
#   kubectl -n NAMESPACE create job restore-now --from=cronjob/NAME-restore
# The schedule is only required syntax; suspend keeps it from ever firing.
resource "kubernetes_cron_job_v1" "restore" {
  metadata {
    name      = "${var.name}-restore"
    namespace = var.namespace
    labels    = local.labels
  }

  spec {
    schedule                      = "0 0 1 1 *"
    suspend                       = true
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 1

    job_template {
      metadata {
        labels = local.labels
      }

      spec {
        backoff_limit              = 0
        ttl_seconds_after_finished = 86400

        template {
          metadata {
            labels = local.labels
          }

          spec {
            service_account_name            = kubernetes_service_account_v1.restore.metadata[0].name
            automount_service_account_token = true
            restart_policy                  = "Never"

            container {
              name    = "restore"
              image   = var.image
              command = ["/bin/sh", "/scripts/restore.sh"]

              env {
                name  = "S3_ENDPOINT"
                value = var.s3.endpoint
              }
              env {
                name  = "S3_BUCKET"
                value = var.s3.bucket
              }
              env {
                name  = "S3_REGION"
                value = var.s3.region
              }
              env {
                name  = "S3_PREFIX"
                value = var.s3.prefix
              }
              env {
                name = "S3_ACCESS_KEY"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.s3.metadata[0].name
                    key  = "access_key"
                  }
                }
              }
              env {
                name = "S3_SECRET_KEY"
                value_from {
                  secret_key_ref {
                    name = kubernetes_secret_v1.s3.metadata[0].name
                    key  = "secret_key"
                  }
                }
              }

              resources {
                requests = {
                  cpu    = var.resources.requests_cpu
                  memory = var.resources.requests_memory
                }
                limits = {
                  cpu    = var.resources.limits_cpu
                  memory = var.resources.limits_memory
                }
              }

              security_context {
                allow_privilege_escalation = false
                read_only_root_filesystem  = true
                run_as_non_root            = true
                run_as_user                = 65532

                capabilities {
                  drop = ["ALL"]
                }

                seccomp_profile {
                  type = "RuntimeDefault"
                }
              }

              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }

              volume_mount {
                name       = "tmp"
                mount_path = "/tmp"
              }
            }

            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map_v1.scripts.metadata[0].name
                default_mode = "0555"
              }
            }

            volume {
              name = "tmp"
              empty_dir {}
            }
          }
        }
      }
    }
  }
}
