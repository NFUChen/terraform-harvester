# github-actions-runner

Creates one Ubuntu VM on Harvester per supplied registration token and registers each VM as a persistent GitHub Actions self-hosted runner. The VMs need outbound HTTPS access to GitHub; no inbound Internet access is required.

## Usage

```hcl
module "github_actions_runner" {
  source = "./modules/github-actions-runner"

  name       = "github-actions-runner"
  root_image = data.harvester_image.ubuntu_24_04_noble_cloud.id
  github_url = "https://github.com/example/example-repository"

  # Comma-separated, short-lived tokens. This example creates
  # github-actions-runner-01 and github-actions-runner-02.
  registration_tokens = var.github_runner_registration_tokens

  ssh_authorized_keys = [file("~/.ssh/id_ed25519.pub")]
  labels              = ["harvester", "linux", "x64"]
}
```

A single token keeps the base `name`. Multiple tokens create runners suffixed with a stable two-digit index (`-01`, `-02`, and so on). Whitespace around each comma-separated token is ignored; empty entries are rejected.

The default management-network interface uses DHCP and masquerade networking. To attach the runners to a VLAN instead:

```hcl
network = {
  name = "default/v100"
}
```

## Included tools

The runner installs a practical Ubuntu CI baseline rather than attempting to reproduce the entire GitHub-hosted runner image and toolcache:

- GitHub CLI (`gh`) from GitHub's signed apt repository
- Docker Engine and access for the `actions` user by default
- Git, curl, wget, jq, SSH, rsync, tar, zip, and unzip
- GCC/build tools and ShellCheck
- Python 3, pip, and venv
- Node.js and npm
- OpenJDK 17

## Token lifecycle

`registration_tokens` contains short-lived tokens generated in GitHub under repository or organization **Settings → Actions → Runners → New self-hosted runner**. Supply one token per runner. The tokens are only needed during first boot, but remain sensitive because they are stored in Terraform state and Harvester cloud-init Secrets. Protect the state and namespace accordingly.

Changing cloud-init inputs replaces the VMs. Supply fresh registration tokens before applying such a change. Each runner uses `--replace`, so recreating a VM under the same name replaces the old GitHub registration.

## Network access

Allow outbound TCP 443 and DNS. At minimum, runner bootstrap needs the GitHub CLI repository, GitHub releases, and Actions endpoints. Workflows may additionally need package registries, artifact storage, container registries, or deployment targets. The module opens no inbound Internet ports.
