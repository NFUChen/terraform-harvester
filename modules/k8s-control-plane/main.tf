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
  join_token = "${random_string.join_token_id.result}.${random_string.join_token_secret.result}"
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
    wait_for_lease = true
  }]

  cloudinit = {
    user_data = templatefile("${path.module}/userdata.yaml", {
      join_token          = local.join_token
      kubernetes_version  = var.kubernetes_version
      pod_network_cidr    = var.pod_network_cidr
      ssh_authorized_keys = var.ssh_authorized_keys
    })
  }

  tags = {
    "ssh-user" = "ubuntu"
  }
}
