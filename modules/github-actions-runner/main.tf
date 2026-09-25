locals {
  runner_labels = join(",", sort(tolist(var.labels)))

  user_data = templatefile("${path.module}/userdata.yaml", {
    github_url          = var.github_url
    registration_token  = var.registration_token
    runner_name         = var.name
    runner_group        = var.runner_group
    runner_labels       = local.runner_labels
    runner_version      = var.runner_version
    runner_sha256       = var.runner_sha256
    install_docker      = var.install_docker
    ssh_authorized_keys = var.ssh_authorized_keys
  })
}

module "runner" {
  source = "../virtual-machine"

  name        = var.name
  namespace   = var.namespace
  description = "GitHub Actions self-hosted runner"

  cpu          = var.cpu
  memory       = var.memory
  run_strategy = "Always"

  root_image     = var.root_image
  root_disk_size = var.root_disk_size

  network_interfaces = [{
    name           = "nic-1"
    network_name   = var.network.name
    type           = var.network.name == null ? "masquerade" : "bridge"
    wait_for_lease = var.network.wait_for_lease
  }]

  cloudinit = {
    user_data = local.user_data
  }

  tags = {
    "ssh-user" = "ubuntu"
  }
}
