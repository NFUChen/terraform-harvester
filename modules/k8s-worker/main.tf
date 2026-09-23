module "worker" {
  source = "../virtual-machine"

  name_prefix    = var.name_prefix
  instance_count = 1
  namespace      = var.namespace

  cpu    = var.cpu
  memory = var.memory

  root_image     = var.root_image
  root_disk_size = var.root_disk_size

  network_interfaces = [{
    name           = "cluster"
    network_name   = var.network.name
    type           = "bridge"
    wait_for_lease = true
  }]

  cloudinit = {
    user_data = templatefile("${path.module}/userdata.yaml", {
      cluster_generation  = var.cluster_generation
      join_command        = var.join_command
      kubernetes_version  = var.kubernetes_version
      ssh_authorized_keys = var.ssh_authorized_keys
    })
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

  tags = {
    "ssh-user" = "ubuntu"
  }
}
