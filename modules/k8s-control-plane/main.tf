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

  user_data = templatefile("${path.module}/userdata.yaml", {
    control_plane_ip    = local.control_plane_ip
    join_token          = local.join_token
    kubernetes_version  = var.kubernetes_version
    pod_network_cidr    = var.pod_network_cidr
    ssh_authorized_keys = var.ssh_authorized_keys
  })

  # The VM has exactly one NIC, but its kernel name depends on the guest's
  # PCI topology. Match on the name glob instead of hardcoding enp1s0 so a
  # renamed interface cannot silently leave the control plane unaddressed.
  network_data = yamlencode({
    version = 2
    ethernets = {
      primary = {
        match = {
          name = "en*"
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

  network_interfaces = [{
    name           = "nic-1"
    network_name   = var.network.name
    type           = "bridge"
    wait_for_lease = true
  }]

  cloudinit = {
    user_data    = local.user_data
    network_data = local.network_data
  }

  tags = {
    "ssh-user" = "ubuntu"
  }
}
