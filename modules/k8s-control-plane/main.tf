resource "random_string" "join_token_id" {
  length  = 6
  upper   = false
  special = false
}

resource "random_string" "join_token_secret" {
  length  = 16
  upper   = false
  special = false
}

locals {
  join_token       = "${random_string.join_token_id.result}.${random_string.join_token_secret.result}"
  control_plane_ip = split("/", var.network.address)[0]

  mac_seed       = md5("${var.namespace}/${var.name_prefix}")
  management_mac = "02:${substr(local.mac_seed, 0, 2)}:${substr(local.mac_seed, 2, 2)}:${substr(local.mac_seed, 4, 2)}:${substr(local.mac_seed, 6, 2)}:01"
  cluster_mac    = "02:${substr(local.mac_seed, 0, 2)}:${substr(local.mac_seed, 2, 2)}:${substr(local.mac_seed, 4, 2)}:${substr(local.mac_seed, 6, 2)}:02"

  load_balancer_cert_sans = join(",", [
    local.control_plane_ip,
    var.load_balancer.address,
  ])

  management_client_cidr = cidrsubnet(var.load_balancer.subnet, 0, 0)

  user_data = templatefile("${path.module}/userdata.yaml", {
    control_plane_ip        = local.control_plane_ip
    apiserver_cert_sans     = local.load_balancer_cert_sans
    join_token              = local.join_token
    kubernetes_version      = var.kubernetes_version
    pod_network_cidr        = var.pod_network_cidr
    flannel_version         = var.cni.version
    flannel_manifest_sha256 = var.cni.manifest_sha256
    ssh_authorized_keys     = var.ssh_authorized_keys
  })

  # Kernel interface names depend on guest PCI topology, so both NICs are
  # matched by their pinned MAC instead of by name. The management NIC exists
  # only so the Harvester LoadBalancer controller (which only has pod-network
  # reachability) can reach this VM; it must not become the default route,
  # because worker joins and outbound traffic stay on the cluster VLAN.
  network_data = yamlencode({
    version = 2
    ethernets = {
      management = {
        match = {
          macaddress = local.management_mac
        }
        dhcp4 = true
        "dhcp4-overrides" = {
          use-routes = false
          use-dns    = false
        }
        # LB health checks originate in the Harvester pod CIDR, while actual
        # API clients arrive from the management LAN. Both enter through the
        # masquerade NIC, so explicit routes prevent replies from escaping via
        # the cluster VLAN default route.
        routes = [
          {
            to  = var.load_balancer.harvester_pod_cidr
            via = var.load_balancer.management_guest_gateway
          },
          {
            to  = local.management_client_cidr
            via = var.load_balancer.management_guest_gateway
          },
        ]
      }
      cluster = {
        match = {
          macaddress = local.cluster_mac
        }
        dhcp4     = false
        addresses = [var.network.address]
        routes = [{
          to  = "default"
          via = var.network.gateway
        }]
        nameservers = {
          addresses = var.network.dns_servers
        }
      }
    }
  })
}

module "control_plane" {
  source = "../virtual-machine"

  name_prefix    = var.name_prefix
  instance_count = 1
  namespace      = var.namespace

  cpu    = var.cpu
  memory = var.memory

  root_image     = var.root_image
  root_disk_size = var.root_disk_size

  network_interfaces = [
    # Management access. The Harvester management network is a pod network, so
    # KubeVirt only supports masquerade; this is what makes the VM reachable
    # to the LoadBalancer controller, which itself only has pod-network
    # reachability.
    {
      name           = "management"
      type           = "masquerade"
      mac_address    = local.management_mac
      wait_for_lease = true
    },
    {
      name           = "cluster"
      network_name   = var.network.name
      type           = "bridge"
      mac_address    = local.cluster_mac
      wait_for_lease = true
    },
  ]

  cloudinit = {
    user_data    = local.user_data
    network_data = local.network_data
  }

  tags = {
    "ssh-user" = "ubuntu"
  }
}

# The LoadBalancer controller only has pod-network reachability, so it can
# only ever probe/forward to the VM's masquerade management NIC, not the
# cluster VLAN NIC used for kubeadm advertise/worker join.
resource "harvester_ippool" "control_plane" {
  name = var.load_balancer.pool_name

  range {
    start   = var.load_balancer.address
    end     = var.load_balancer.address
    subnet  = var.load_balancer.subnet
    gateway = var.load_balancer.gateway
  }

  # No network/scope selector: this pool exists solely for this control plane's
  # LoadBalancer, which requests it by name.
}

resource "harvester_loadbalancer" "control_plane" {
  name      = var.load_balancer.name
  namespace = var.namespace

  ipam   = "pool"
  ippool = harvester_ippool.control_plane.name

  workload_type = "vm"

  backend_selector {
    key    = "harvesterhci.io/vmName"
    values = module.control_plane.instance_names
  }

  listener {
    name         = "kube-apiserver"
    port         = var.load_balancer.listener_port
    protocol     = "tcp"
    backend_port = 6443
  }

  dynamic "listener" {
    for_each = var.kubeconfig_export.enabled ? [1] : []

    content {
      name         = "ssh"
      port         = var.kubeconfig_export.ssh_port
      protocol     = "tcp"
      backend_port = 22
    }
  }

  healthcheck {
    port              = 6443
    success_threshold = 1
    failure_threshold = 5
    period_seconds    = 30
    timeout_seconds   = 5
  }

  depends_on = [module.control_plane]
}

resource "terraform_data" "kubeconfig_export" {
  count = var.kubeconfig_export.enabled ? 1 : 0

  triggers_replace = {
    control_plane_id = module.control_plane.ids[module.control_plane.instance_names[0]]
    load_balancer_ip = harvester_loadbalancer.control_plane.ip_address
    api_port         = tostring(var.load_balancer.listener_port)
    ssh_port         = tostring(var.kubeconfig_export.ssh_port)
    output_path      = var.kubeconfig_export.output_path
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      API_ENDPOINT     = "https://${harvester_loadbalancer.control_plane.ip_address}:${var.load_balancer.listener_port}"
      KUBECONFIG_PATH  = pathexpand(var.kubeconfig_export.output_path)
      PRIVATE_KEY_PATH = pathexpand(var.kubeconfig_export.private_key_path)
      SOURCE_ENDPOINT  = "https://${local.control_plane_ip}:6443"
      SSH_HOST         = harvester_loadbalancer.control_plane.ip_address
      SSH_PORT         = tostring(var.kubeconfig_export.ssh_port)
      SSH_USER         = var.kubeconfig_export.ssh_user
    }

    command = <<-SCRIPT
      set -euo pipefail
      umask 077
      test -f "$PRIVATE_KEY_PATH"
      mkdir -p "$(dirname "$KUBECONFIG_PATH")"

      for attempt in $(seq 1 60); do
        if ssh \
          -o BatchMode=yes \
          -o ConnectTimeout=5 \
          -o StrictHostKeyChecking=accept-new \
          -i "$PRIVATE_KEY_PATH" \
          -p "$SSH_PORT" \
          "$SSH_USER@$SSH_HOST" \
          'test -s ~/.kube/config && cat ~/.kube/config' > "$KUBECONFIG_PATH.tmp"; then
          break
        fi
        if [ "$attempt" -eq 60 ]; then
          echo "Timed out waiting for control-plane kubeconfig over SSH" >&2
          exit 1
        fi
        sleep 5
      done

      python3 -c 'import pathlib, sys; path = pathlib.Path(sys.argv[1]); path.write_text(path.read_text().replace(sys.argv[2], sys.argv[3]))' "$KUBECONFIG_PATH.tmp" "$SOURCE_ENDPOINT" "$API_ENDPOINT"
      install -m 0600 "$KUBECONFIG_PATH.tmp" "$KUBECONFIG_PATH"
      rm -f "$KUBECONFIG_PATH.tmp"
    SCRIPT
  }

  depends_on = [harvester_loadbalancer.control_plane]
}
