# Workers in a group are homogeneous and already share one SSH key, user data,
# and join token, so they share one console password too. Only the bcrypt hash
# reaches cloud-init; the plaintext stays in state and the sensitive output.
resource "random_password" "ubuntu" {
  length      = 24
  special     = true
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1
}

locals {
  management_client_cidr = cidrsubnet(var.load_balancer.subnet, 0, 0)

  mac_seed = {
    for name in keys(var.instances) : name => md5("${var.namespace}/${name}")
  }

  management_mac = {
    for name, seed in local.mac_seed :
    name => "02:${substr(seed, 0, 2)}:${substr(seed, 2, 2)}:${substr(seed, 4, 2)}:${substr(seed, 6, 2)}:01"
  }

  cluster_mac = {
    for name, seed in local.mac_seed :
    name => "02:${substr(seed, 0, 2)}:${substr(seed, 2, 2)}:${substr(seed, 4, 2)}:${substr(seed, 6, 2)}:02"
  }
}

module "worker" {
  for_each = var.instances
  source   = "../virtual-machine"

  name      = each.key
  namespace = var.namespace

  cpu    = coalesce(each.value.cpu, var.cpu)
  memory = coalesce(each.value.memory, var.memory)

  root_image       = var.root_image
  root_disk_size   = var.root_disk_size
  persistent_disks = each.value.persistent_disks

  network_interfaces = [
    {
      name           = "management"
      type           = "masquerade"
      mac_address    = local.management_mac[each.key]
      wait_for_lease = true
    },
    {
      name           = "cluster"
      network_name   = var.network.name
      type           = "bridge"
      mac_address    = local.cluster_mac[each.key]
      wait_for_lease = true
    },
  ]

  cloudinit = {
    user_data = templatefile("${path.module}/userdata.yaml", {
      cluster_generation = var.cluster_generation
      join_command       = var.join_command
      kubernetes_version = var.kubernetes_version
      node_ip            = split("/", each.value.address)[0]
      persistent_mounts = [
        for disk_name, disk in each.value.persistent_disks : {
          name       = disk_name
          device     = disk.device
          filesystem = disk.filesystem
          mount_path = disk.mount_path
        }
        if disk.device != null
      ]
      ssh_authorized_keys  = var.ssh_authorized_keys
      ubuntu_password_hash = random_password.ubuntu.bcrypt_hash
    })

    network_data = yamlencode({
      version = 2
      ethernets = {
        management = {
          match = {
            macaddress = local.management_mac[each.key]
          }
          dhcp4 = true
          "dhcp4-overrides" = {
            use-routes = false
            use-dns    = false
          }
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
            macaddress = local.cluster_mac[each.key]
          }
          dhcp4     = false
          addresses = [each.value.address]
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

  tags = {
    "ssh-user" = "ubuntu"
  }
}

resource "harvester_ippool" "workers" {
  name = var.load_balancer.pool_name

  range {
    start   = var.load_balancer.address
    end     = var.load_balancer.address
    subnet  = var.load_balancer.subnet
    gateway = var.load_balancer.gateway
  }
}

resource "harvester_loadbalancer" "workers" {
  name      = var.load_balancer.name
  namespace = var.namespace

  ipam          = "pool"
  ippool        = harvester_ippool.workers.name
  workload_type = "vm"

  backend_selector {
    key    = "harvesterhci.io/vmName"
    values = sort(keys(var.instances))
  }

  listener {
    name         = "http"
    port         = var.load_balancer.listener_port
    protocol     = "tcp"
    backend_port = var.load_balancer.backend_port
  }

  healthcheck {
    port              = var.load_balancer.backend_port
    success_threshold = 1
    failure_threshold = 5
    period_seconds    = 10
    timeout_seconds   = 3
  }

  depends_on = [module.worker]
}
