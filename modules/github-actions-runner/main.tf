locals {
  runner_labels = join(",", sort(tolist(var.labels)))

  registration_token_list  = [for token in split(",", var.registration_tokens) : trimspace(token)]
  registration_token_count = length(local.registration_token_list)

  # One runner per registration token. A single token keeps the bare base
  # name so that existing single-runner deployments are not renamed.
  runner_names = [
    for index in range(local.registration_token_count) :
    local.registration_token_count == 1 ? var.name : format("%s-%02d", var.name, index + 1)
  ]

  baseline_packages = [
    "build-essential",
    "ca-certificates",
    "curl",
    # docker.io provides Docker Engine; docker-buildx adds the BuildKit-backed
    # `docker buildx` CLI plugin that Dockerfile `RUN --mount=...` syntax
    # requires. Plain docker.io alone leaves the CLI on the legacy builder.
    "docker.io",
    "docker-buildx",
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
  ]

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
      aws_cli_version     = var.aws_cli_version
      aws_cli_sha256      = var.aws_cli_sha256
      packages            = local.baseline_packages
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
