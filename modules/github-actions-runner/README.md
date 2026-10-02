# github-actions-runner

## Purpose and scope

Creates one Ubuntu Harvester VM per supplied registration token using the sibling
`virtual-machine` module. Bootstraps persistent GitHub Actions self-hosted runners
for a GitHub.com repository or organization. Does not mint tokens, manage GitHub
runner groups, autoscale, or reproduce the GitHub-hosted runner image/toolcache.

## Requirements and providers

| Dependency | Declared constraint / requirement |
| --- | --- |
| Terraform | `>= 1.3` declared; `strcontains` and the child's `terraform_data` require 1.5+ and 1.4+ respectively. Use 1.7+ for mocked tests. |
| `harvester/harvester` | `= 1.9.0` |

Configure the provider in the caller. Supply an existing Ubuntu x86_64 cloud image
with cloud-init and apt packages compatible with the bootstrap, an existing
namespace, and any named network. Guests need DNS and outbound access to Ubuntu
package mirrors, GitHub CLI packages/releases/Actions endpoints, and AWS CLI
downloads; workflows may require additional destinations. Package mirrors can
require HTTP as well as HTTPS. The module creates no inbound exposure rules.

## Default context

Defaults use the base name `github-actions-runner`, namespace `default`, and
2 vCPUs, `4Gi` RAM, and an `80Gi` disposable root disk per token. These are a
starting point for small, trusted CI jobs; override sizing for build memory,
workspace, and cache needs. Runners are persistent services, not per-job VMs.
No SSH keys, custom labels, or runner group are supplied by default.

The bootstrap requires an Ubuntu cloud-init image with compatible apt packages
on x86_64: runner/AWS downloads and the GitHub CLI apt source hard-code that
architecture. Changing version inputs does not add ARM or other OS support.
Omitted networking uses management masquerade with lease waiting, suitable when
jobs only need reachable outbound services. Select a named VLAN when jobs need
that network, and provide DHCP/addressing there. Update version/checksum pairs
together when changing the initial runner or AWS CLI release.

## Usage

Caller configuration snippet, **not a standalone root module**: declare and supply
all referenced variables and configure the provider separately. The source path
assumes the caller is at the **repository root**; adjust it elsewhere.

This example chooses the name `build-runner` and the label `self-hosted-linux`, and
keeps the default namespace, sizing, and management networking. The image, GitHub
target, tokens, and SSH keys remain caller-supplied.

```hcl
module "runners" {
  source = "./modules/github-actions-runner"

  name                = "build-runner"
  root_image          = var.ubuntu_image_id
  github_url          = var.github_url
  registration_tokens = var.runner_registration_tokens
  ssh_authorized_keys = var.runner_ssh_public_keys
  labels              = ["self-hosted-linux"]
}
```

Omit `network` for management-network masquerade with lease waiting. For a named
VLAN NAD, add `network = { name = var.network_id }` inside the module call and
declare/supply that additional caller variable; named networks use bridge mode.

## Inputs

| Name | Type | Required / default | Meaning |
| --- | --- | --- | --- |
| `name` | `string` | `"github-actions-runner"` | Base VM/agent name; lowercase DNS-compatible label, at most 60 characters. |
| `namespace` | `string` | `"default"` | Existing Harvester namespace. |
| `root_image` | `string` | Required | Ubuntu x86_64 Harvester image ID (`name` or `namespace/name`). |
| `github_url` | `string` | Required | HTTPS GitHub.com organization or repository URL; optional trailing slash. Other hosts are rejected. |
| `registration_tokens` | `string` | Required | Non-empty comma-separated short-lived registration tokens, one per runner; whitespace trimmed, empty entries rejected. Not declared sensitive. |
| `cpu` | `number` | `2` | vCPUs per runner; child requires a positive integer. |
| `memory` | `string` | `"4Gi"` | Memory per runner as a supported Kubernetes quantity. |
| `root_disk_size` | `string` | `"80Gi"` | VM-owned root disk quantity. |
| `network` | `object` | `{}` | Optional string `name = null` (management network; otherwise NAD `namespace/name`) and bool `wait_for_lease = true`. |
| `ssh_authorized_keys` | `list(string)` | `[]` | Public SSH keys for the `ubuntu` user. |
| `labels` | `set(string)` | `[]` | Additional runner labels, sorted for rendering; non-blank and without commas. |
| `runner_group` | `string` | `null` | Optional existing runner group name. |
| `runner_version` | `string` | `"2.337.0"` | Initial linux-x64 runner release; numeric three-part version without `v`. |
| `runner_sha256` | `string` | `"70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613"` | Runner tarball checksum; 64 lowercase hex characters. |
| `aws_cli_version` | `string` | `"2.37.4"` | AWS CLI v2 Linux x86_64 installer release; `2.x.y`. |
| `aws_cli_sha256` | `string` | `"0c59444563f4df735eeb5481f6165f95dae546c33761760d8be9855d5cfe2d12"` | AWS CLI installer checksum; 64 lowercase hex characters. |

## Outputs

| Output | Meaning |
| --- | --- |
| `names` | Ordered VM/agent names, one per token position. |
| `ids` | VM IDs keyed by runner name. |
| `primary_ip_addresses` | Primary IPs keyed by runner name; may be empty until reported. |
| `states` | Provider-derived VM states keyed by runner name; not proof of GitHub registration or job readiness. |

## Behavior and limitations / lifecycle

- One token uses the bare base name. Multiple tokens use positional suffixes
  `-01`, `-02`, and so on (minimum two digits). Identity depends on token **count
  and position**, not token value: switching between one and multiple tokens
  renames/replaces runners. Adding/removing/reordering entries can remove VMs or
  change which token belongs to a surviving name. Duplicate tokens are not rejected.
- Tokens come from GitHub's runner registration flow, not a PAT input. Use fresh
  short-lived tokens for first boot and replacement. Changing a token changes
  cloud-init and replaces its VM; changing other rendered bootstrap inputs also
  replaces affected VMs. Root disks and workspaces are deleted on replacement.
- Runners use `Always`, register with `--replace`, and run as a persistent system
  service under `actions`. Same-name registration can replace an existing GitHub
  runner. There is no deregistration-on-destroy hook or per-job cleanup guarantee.
- Bootstrap installs Docker Engine/Buildx, GitHub CLI, AWS CLI v2, Git, build tools,
  ShellCheck, Python/pip/venv, Node.js/npm, OpenJDK 17, transfer/archive utilities,
  and the guest agent. Runner and AWS CLI downloads are checksum-verified; apt
  packages are not version-pinned. Update each version/checksum pair together.
  Runner auto-update is not disabled, so the initial version is not a permanent pin.
- Tokens appear in Terraform state, cloud-init Secret data, and the guest's
  root-only bootstrap script. Inputs are not marked sensitive; protect plans,
  state, logs, and Secret access. Marking caller values sensitive does not encrypt
  state and can make this implementation's token-derived `for_each` keys invalid:
  token count determines runner names. Do not assume sensitive caller variables
  work unchanged; do not use `nonsensitive` as a confidentiality control.
- Both `ubuntu` and `actions` have passwordless sudo; `actions` also has Docker
  access. Treat jobs as trusted privileged code, isolate runner networks and
  credentials, and avoid untrusted pull-request workloads. Template values are
  interpolated into shell/YAML, not generally escaped; accept only trusted inputs.

## Testing

Run from `modules/github-actions-runner` with Terraform 1.7+:

```sh
terraform init -backend=false
terraform validate
terraform test
```

Tests use a mocked provider to check runner naming, network selection, rendered
bootstrap, and input validation. They do not exercise downloads, guest bootstrap,
GitHub registration, or job execution. Provider installation requires registry
access or a configured mirror/cache.
