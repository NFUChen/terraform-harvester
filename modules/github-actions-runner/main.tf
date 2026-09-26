locals {
  runner_labels = join(",", sort(tolist(var.labels)))

  # Splitting the sensitive registration_tokens string keeps every derived
  # value sensitive, including the resulting list itself. The *count* of
  # tokens is not secret on its own, so that marking is stripped explicitly
  # in order to build deterministic, index-based runner names that Terraform
  # can use in for_each (which rejects sensitive keys/sets). The names never
  # contain a token; only local.user_data below pairs a name back up with
  # its (still sensitive) token by matching list position.
  registration_token_list  = [for token in split(",", var.registration_tokens) : trimspace(token)]
  registration_token_count = length(nonsensitive(local.registration_token_list))

  # One runner per registration token. A single token keeps the bare base
  # name so that existing single-runner deployments are not renamed.
  runner_names = [
    for index in range(local.registration_token_count) :
    local.registration_token_count == 1 ? var.name : format("%s-%02d", var.name, index + 1)
  ]

  baseline_packages = concat(
    [
      "build-essential",
      "ca-certificates",
      "curl",
      "git",
      "gnupg",
      "jq",
      "nodejs",
      "npm",
      "openjdk-17-jdk",
      "openssh-client",
      "python3",
      "python3-pip",
      "python3-venv",
      "qemu-guest-agent",
      "rsync",
      "shellcheck",
      "tar",
      "unzip",
      "wget",
      "zip",
    ],
    var.install_docker ? ["docker.io"] : [],
  )

  user_data = {
    for index, runner_name in local.runner_names :
    runner_name => templatefile("${path.module}/userdata.yaml", {
      github_url          = var.github_url
      registration_token  = local.registration_token_list[index]
      runner_name         = runner_name
      runner_group        = var.runner_group
      runner_labels       = local.runner_labels
      runner_version      = var.runner_version
      runner_sha256       = var.runner_sha256
      packages            = local.baseline_packages
      install_docker      = var.install_docker
      ssh_authorized_keys = var.ssh_authorized_keys
    })
  }
}

module "runner" {
  source   = "../virtual-machine"
  for_each = toset(local.runner_names)

  name        = each.key
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
    user_data = local.user_data[each.key]
  }

  tags = {
    "ssh-user" = "ubuntu"
  }
}
