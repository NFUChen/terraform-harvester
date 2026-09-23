locals {
  namespace    = split("/", var.network_id)[0]
  network_name = split("/", var.network_id)[1]
  name_prefix  = coalesce(var.name_prefix, local.network_name)

  prefix_length = tonumber(split("/", var.cidr)[1])
  netmask       = cidrnetmask(var.cidr)
  gateway       = cidrhost(var.cidr, var.gateway_offset)
  server_ip     = cidrhost(var.cidr, var.server_offset)
  pool_start    = cidrhost(var.cidr, var.pool_start_offset)
  pool_end      = cidrhost(var.cidr, var.pool_end_offset)
  dns_servers   = coalesce(var.dns_servers, [local.gateway])
  dns_server    = join(",", local.dns_servers)

  labels = merge(
    var.labels,
    {
      "app.kubernetes.io/name"       = "vlan-dhcp"
      "app.kubernetes.io/instance"   = local.name_prefix
      "app.kubernetes.io/managed-by" = "terraform"
    }
  )

  multus_annotation = jsonencode([{
    name      = local.network_name
    namespace = local.namespace
    interface = "net1"
  }])

  dnsmasq_config = join("\n", compact([
    "port=0",
    "interface=net1",
    "bind-interfaces",
    "dhcp-authoritative",
    "dhcp-range=${local.pool_start},${local.pool_end},${local.netmask},${var.lease_time}",
    "dhcp-option=option:router,${local.gateway}",
    "dhcp-option=option:dns-server,${local.dns_server}",
    var.domain == null ? null : "dhcp-option=option:domain-name,${var.domain}",
    "dhcp-leasefile=/tmp/dnsmasq.leases",
    "pid-file=",
    "log-dhcp",
    "log-facility=-",
  ]))
}

resource "kubernetes_config_map_v1" "dhcp" {
  metadata {
    name      = "${local.name_prefix}-dhcp"
    namespace = local.namespace
    labels    = local.labels
  }

  data = {
    "dnsmasq.conf" = local.dnsmasq_config
  }
}

resource "kubernetes_deployment_v1" "dhcp" {
  metadata {
    name      = "${local.name_prefix}-dhcp"
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1

    strategy {
      # Two replicas must never answer from the same server IP and pool.
      type = "Recreate"
    }

    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "vlan-dhcp"
        "app.kubernetes.io/instance" = local.name_prefix
      }
    }

    template {
      metadata {
        labels = local.labels
        annotations = {
          "k8s.v1.cni.cncf.io/networks" = local.multus_annotation
          "checksum/dnsmasq-config"     = sha256(local.dnsmasq_config)
        }
      }

      spec {
        automount_service_account_token = false
        node_selector                   = var.node_selector

        container {
          name  = "dnsmasq"
          image = var.image

          image_pull_policy = "IfNotPresent"

          command = ["/bin/sh", "-ec"]
          args = [<<-SCRIPT
            command -v dnsmasq >/dev/null || { echo "dnsmasq binary missing" >&2; exit 1; }
            command -v ip >/dev/null || { echo "ip command missing; image must provide link set and addr replace operations" >&2; exit 1; }
            ip link set net1 up
            ip addr replace ${local.server_ip}/${local.prefix_length} dev net1
            exec dnsmasq --keep-in-foreground --conf-file=/etc/dnsmasq.d/dnsmasq.conf
          SCRIPT
          ]

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = false
            run_as_user                = 0

            capabilities {
              drop = ["ALL"]
              add  = ["NET_ADMIN", "NET_RAW", "NET_BIND_SERVICE", "SETUID", "SETGID"]
            }

            seccomp_profile {
              type = "RuntimeDefault"
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

          volume_mount {
            name       = "config"
            mount_path = "/etc/dnsmasq.d"
            read_only  = true
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          readiness_probe {
            exec {
              command = [
                "/bin/sh",
                "-ec",
                "ip -4 addr show dev net1 | grep -F 'inet ${local.server_ip}/${local.prefix_length}' >/dev/null && netstat -uln | grep -E '(^|:)67[[:space:]]' >/dev/null",
              ]
            }
            initial_delay_seconds = 2
            period_seconds        = 5
            failure_threshold     = 3
          }

          liveness_probe {
            exec {
              command = [
                "/bin/sh",
                "-ec",
                "ip -4 addr show dev net1 | grep -F 'inet ${local.server_ip}/${local.prefix_length}' >/dev/null && netstat -uln | grep -E '(^|:)67[[:space:]]' >/dev/null",
              ]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            failure_threshold     = 3
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map_v1.dhcp.metadata[0].name
          }
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.gateway_offset != var.server_offset
      error_message = "gateway_offset and server_offset must be different addresses."
    }
  }
}
