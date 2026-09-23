locals {
  namespace     = split("/", var.network_id)[0]
  network_name  = split("/", var.network_id)[1]
  name_prefix   = coalesce(var.name_prefix, local.network_name)
  prefix_length = tonumber(split("/", var.cidr)[1])
  gateway_ip    = cidrhost(var.cidr, var.gateway_offset)
  labels = merge(var.labels, {
    "app.kubernetes.io/name"       = "vlan-nat-gateway"
    "app.kubernetes.io/instance"   = local.name_prefix
    "app.kubernetes.io/managed-by" = "terraform"
  })
  multus_annotation = jsonencode([{
    name      = local.network_name
    namespace = local.namespace
    interface = "net1"
  }])
}

resource "kubernetes_deployment_v1" "gateway" {
  metadata {
    name      = "${local.name_prefix}-nat"
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector {
      match_labels = {
        "app.kubernetes.io/name"     = "vlan-nat-gateway"
        "app.kubernetes.io/instance" = local.name_prefix
      }
    }
    template {
      metadata {
        labels = local.labels
        annotations = {
          "k8s.v1.cni.cncf.io/networks" = local.multus_annotation
        }
      }
      spec {
        automount_service_account_token = false
        node_selector                   = var.node_selector

        # net.ipv4.ip_forward is namespaced per Pod and defaults to 0 on this
        # RKE2 cluster. A short-lived privileged init container enables it in
        # the shared Pod network namespace; the long-running gateway container
        # remains non-privileged with only NET_ADMIN/NET_RAW.
        init_container {
          name    = "enable-ip-forwarding"
          image   = var.image
          command = ["/bin/sh", "-ec", "sysctl -w net.ipv4.ip_forward=1"]

          security_context {
            privileged  = true
            run_as_user = 0
          }
        }

        container {
          name              = "gateway"
          image             = var.image
          image_pull_policy = "IfNotPresent"
          command           = ["/bin/sh", "-ec"]
          args = [<<-SCRIPT
            command -v ip >/dev/null
            command -v iptables >/dev/null
            test "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" || { echo "kernel ip_forward is disabled" >&2; exit 1; }
            ip link set net1 up
            ip addr replace ${local.gateway_ip}/${local.prefix_length} dev net1
            iptables -t nat -C POSTROUTING -s ${var.cidr} -o eth0 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${var.cidr} -o eth0 -j MASQUERADE
            iptables -t mangle -C FORWARD -i net1 -o eth0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -i net1 -o eth0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
            iptables -C FORWARD -i net1 -o eth0 -s ${var.cidr} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i net1 -o eth0 -s ${var.cidr} -j ACCEPT
            iptables -C FORWARD -i eth0 -o net1 -d ${var.cidr} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i eth0 -o net1 -d ${var.cidr} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
            exec sleep infinity
          SCRIPT
          ]
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_user                = 0
            capabilities {
              drop = ["ALL"]
              add  = ["NET_ADMIN", "NET_RAW"]
            }
            seccomp_profile { type = "RuntimeDefault" }
          }
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { cpu = "200m", memory = "128Mi" }
          }
          readiness_probe {
            exec {
              command = ["/bin/sh", "-ec", "ip -4 addr show dev net1 | grep -F 'inet ${local.gateway_ip}/${local.prefix_length}' >/dev/null && iptables -t nat -C POSTROUTING -s ${var.cidr} -o eth0 -j MASQUERADE && iptables -t mangle -C FORWARD -i net1 -o eth0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"]
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }
          liveness_probe {
            exec {
              command = ["/bin/sh", "-ec", "test \"$(cat /proc/sys/net/ipv4/ip_forward)\" = 1 && iptables -t nat -C POSTROUTING -s ${var.cidr} -o eth0 -j MASQUERADE"]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }
}
