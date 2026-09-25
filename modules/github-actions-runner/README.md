# github-actions-runner

Creates one Ubuntu VM on Harvester and registers it as a persistent GitHub Actions self-hosted runner. The VM needs outbound HTTPS access to GitHub; no inbound Internet access is required.

## Usage

```hcl
module "github_actions_runner" {
  source = "./modules/github-actions-runner"

  name       = "github-actions-runner-01"
  root_image = data.harvester_image.ubuntu_24_04_noble_cloud.id
  github_url = "https://github.com/example/example-repository"

  # Create a short-lived registration token immediately before apply.
  registration_token = var.github_runner_registration_token

  ssh_authorized_keys = [file("~/.ssh/id_ed25519.pub")]
  labels              = ["harvester", "linux", "x64"]
}
```

The default management-network interface uses DHCP and masquerade networking. To attach the runner to a VLAN instead:

```hcl
network = {
  name = "default/v100"
}
```

## Token lifecycle

`registration_token` is a short-lived token generated in GitHub under repository or organization **Settings → Actions → Runners → New self-hosted runner**. It is only needed during first boot, but it is sensitive and is stored in Terraform state and the Harvester cloud-init Secret. Protect the state and namespace accordingly.

Changing cloud-init inputs replaces the VM. Supply a fresh registration token before applying such a change. The runner uses `--replace`, so recreating the VM under the same name replaces the old GitHub registration.

## Network access

Allow outbound TCP 443 and DNS. At minimum, the runner bootstrap and agent need GitHub release and Actions endpoints. Workflows may additionally need package registries, artifact storage, container registries, or deployment targets. The module opens no inbound Internet ports.
