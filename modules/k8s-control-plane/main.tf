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

  healthcheck {
    port              = 6443
    success_threshold = 1
    failure_threshold = 5
    period_seconds    = 30
    timeout_seconds   = 5
  }

  depends_on = [module.control_plane]
}
