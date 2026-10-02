# Harvester Infrastructure

Terraform infrastructure for running an Ubuntu-based Kubernetes cluster and GitHub Actions runners on an existing Harvester cluster.

The architecture separates long-lived platform resources—images, VLAN networking, and protected data volumes—from replaceable virtual machines. Kubernetes is bootstrapped inside the VMs with cloud-init, containerd, and kubeadm.

> **Current status:** This is an environment-specific lab configuration, not a production-ready or one-command deployment. The foundation stack references a backup module whose source is currently missing. Review [Known limitations](#known-limitations) before running Terraform. Addresses and versions below describe the configuration, not verified live infrastructure.

## Architecture

```text
Operator workstation / CI
  |
  | Terraform + Harvester management kubeconfig
  v
Existing Harvester cluster
  |
  +-- fundamental/                         Long-lived foundation state
  |   +-- Ubuntu installation ISO and cloud image
  |   +-- v100: VLAN 100, 172.16.100.0/24
  |   |   +-- NAT gateway: 172.16.100.1
  |   |   +-- DHCP server: 172.16.100.2
  |   |   +-- DHCP pool: 172.16.100.100–200
  |   +-- Protected app-data volume: 100 GiB
  |   +-- PVC deletion/label admission policy
  |
  +-- vm/                                  Replaceable compute state
      +-- Harvester LoadBalancer: 192.168.18.240
      |   +-- TCP 6443 -> control-plane Kubernetes API
      |   +-- TCP 22   -> control-plane SSH / kubeconfig export
      +-- k8s-control-plane-01: 172.16.100.10
      +-- stateful-worker-01:   172.16.100.20
      |   +-- app-data -> /dev/vdb -> /mnt/app-data
      +-- k8s-worker-02:        172.16.100.21
      +-- k8s-worker-03:        172.16.100.22
      +-- GitHub Actions runner VMs: DHCP on v100
```

There are **two Kubernetes API layers**:

- **Harvester management cluster:** Terraform provisions VMs, networks, images, volumes, and host-side network services here.
- **Guest Kubernetes cluster:** kubeadm creates this cluster inside the VMs. Applications run here, using the exported `vm/kubeconfig`.

Do not interchange their kubeconfigs.

### Networking

The foundation creates `harvester-public/v100` on the existing `mgmt` ClusterNetwork. DHCP and NAT are separate, single-replica Kubernetes Deployments on the **Harvester cluster**, selected onto the configured `local-harvester` node.

Kubernetes VMs have two interfaces:

- A **masquerade management interface** for Harvester pod-network reachability. DHCP routes and DNS from this interface are disabled.
- A **bridged VLAN interface** with a static address. Cluster traffic and the default route use VLAN 100 through `172.16.100.1`.

The Harvester LoadBalancer forwards through the control-plane management interface, while worker joins use the control-plane VLAN address. The guest API certificate includes both the VLAN address and the management-facing LoadBalancer address.

### Guest Kubernetes bootstrap

Cloud-init installs containerd, Kubernetes packages, and the QEMU guest agent. The control plane runs `kubeadm init`, then installs checksum-verified Flannel and metrics-server manifests. Workers join through the generated bootstrap command.

Current settings:

| Setting | Configured value |
| --- | --- |
| Guest OS | Ubuntu 24.04 Noble cloud image |
| Kubernetes package repository minor | `1.36` in `vm/main.tf` |
| Control plane | 1 VM, 2 vCPUs, 4 GiB RAM, 40 GiB root disk |
| Workers | 3 VMs, each with 4 vCPUs and 8 GiB RAM |
| Pod CIDR | `10.244.0.0/16` |
| Flannel | `v0.28.9` |
| metrics-server | `v0.7.2`, enabled by default |
| External guest API | `https://192.168.18.240:6443` |

The version setting selects a Kubernetes minor-version package repository, not an exact patch version. Verify package availability and compatibility before deployment.

After the control plane becomes reachable, Terraform retrieves its admin kubeconfig over SSH, rewrites the API endpoint to the LoadBalancer address, and saves it as `vm/kubeconfig`.

### Persistent storage and protection

The `app-data` volume is managed in the foundation state independently of worker VMs. It uses `harvester-longhorn`, `Block` mode, and `ReadWriteOnce` access. The stateful worker attaches the existing volume and mounts it as ext4 at `/mnt/app-data`.

This is a **host filesystem mount inside a VM**, not an automatically provisioned guest Kubernetes PVC. Application manifests and guest-cluster storage integration are separate concerns.

Protection has two layers:

1. Terraform lifecycle rules prevent ordinary destruction of protected resources while their configuration remains present.
2. A Harvester-cluster admission policy denies deletion of protected PVCs and removal of their protection label, except for explicitly allowed break-glass usernames.

The current break-glass list includes `system:admin`. Using that identity for routine work bypasses the admission protection. Production use requires separate operational identities, restricted policy administration, and auditing.

See the [protected-volume runbook](modules/protected-volume/README.md) and [volume-protection-policy documentation](modules/volume-protection-policy/README.md). Deletion protection is **not a backup**.

## Repository layout

```text
.
├── fundamental/                 Foundation Terraform root configuration
├── vm/                          VM and guest-cluster Terraform root configuration
├── modules/
│   ├── protected-network/       Protected VLAN network + optional DHCP/NAT
│   ├── vlan-dhcp/               VLAN DHCP service
│   ├── vlan-nat-gateway/        VLAN egress gateway
│   ├── protected-volume/        Long-lived Harvester data volumes
│   ├── volume-protection-policy/  Cluster-level PVC admission protection
│   ├── virtual-machine/         Shared VM, disk, NIC, and cloud-init abstraction
│   ├── k8s-control-plane/       kubeadm control plane, LoadBalancer, export
│   ├── k8s-worker-group/        Worker instances and persistent disk mounts
│   └── github-actions-runner/   Persistent self-hosted runner VMs
├── guest-addons/                No Terraform source currently present
├── autoscaler/                  Kubernetes autoscaler source tree
├── .github/workflows/           Terraform module test workflow
└── provider.tf                 Incomplete top-level provider configuration
```

`fundamental/` and `vm/` are independent Terraform roots. The VM stack discovers foundation resources by fixed names through Harvester data sources; it does not consume Terraform remote-state outputs. Apply order and matching resource names therefore matter.

The repository-level `provider.tf` references undeclared variables and is not the deployment entry point. Run Terraform with `-chdir=fundamental`, `-chdir=vm`, or inside an individual module.

**Checkout caveat:** The current `.gitignore` excludes `fundamental/` and `vm/`. Local files in those directories may not be present in a fresh clone unless already tracked. Verify that the intended root configurations are distributed before treating this repository as reproducible infrastructure.

## Prerequisites

- An existing, reachable Harvester cluster; this repository does not install Harvester itself.
- Terraform **1.12.2 recommended**, matching CI and supporting the module validation/test features in use.
- Harvester provider **1.9.0**; the foundation also uses Kubernetes provider `~> 2.38`.
- A Harvester kubeconfig with the required resource permissions. The stacks default to `~/.kube/harvester.yaml`.
- An existing, ready `mgmt` ClusterNetwork and the necessary VLAN/uplink configuration on eligible nodes.
- Available, non-conflicting VLAN addresses and a reserved management LoadBalancer address reachable from the Terraform workstation.
- A cluster API supporting `admissionregistration.k8s.io/v1` `ValidatingAdmissionPolicy` and `ValidatingAdmissionPolicyBinding`.
- Longhorn storage and the `harvester-longhorn` StorageClass.
- Outbound access for image downloads, Ubuntu/Kubernetes packages, GitHub release manifests, and GitHub Actions registration.
- Bash, OpenSSH, Python 3, and `kubectl` on the operator workstation. The kubeconfig export runs locally during apply.
- Fresh GitHub Actions registration tokens if deploying the runner module.

## Deployment workflow

### 1. Review environment-specific configuration

Before initialization, resolve the missing backup module described below and inspect:

| File | Values to review |
| --- | --- |
| `fundamental/net.tf` | ClusterNetwork, VLAN, CIDR, DHCP pool, DNS, node selector |
| `fundamental/images.tf` | Image URLs, availability, and names |
| `fundamental/volumes.tf` | Data volume, StorageClass, break-glass users, backup module reference |
| `vm/main.tf` | Static addresses, LoadBalancer range, Kubernetes version, resources, runner tokens |
| `vm/variables.tf` | Harvester access and GitHub organization/repository URL |

The VM stack currently embeds runner registration tokens directly in `vm/main.tf`. Do not reuse or publish them. Replace this with sensitive variable or secret-management input and supply fresh, short-lived tokens. Changes to runner bootstrap inputs may replace runner VMs.

Use an absolute kubeconfig path to avoid differences in tilde expansion:

```sh
export TF_VAR_kubeconfig="$HOME/.kube/harvester.yaml"
# Optional:
# export TF_VAR_kubecontext="your-harvester-context"
```

These variables select the **Harvester management cluster**, not the guest cluster.

### 2. Apply the foundation

**These commands require the missing backup-module reference to be resolved first.** A module with `count = 0` still needs valid source code during initialization.

```sh
terraform -chdir=fundamental init
terraform -chdir=fundamental validate
terraform -chdir=fundamental plan -out=foundation.tfplan
terraform -chdir=fundamental apply foundation.tfplan
```

Confirm image readiness, DHCP/NAT service health, and volume availability before creating VMs.

### 3. Apply compute

```sh
terraform -chdir=vm init
terraform -chdir=vm validate
terraform -chdir=vm plan -out=compute.tfplan
terraform -chdir=vm apply compute.tfplan
```

Terraform generates an RSA SSH key at `vm/rsa_4096_master.pem` and exports the guest admin kubeconfig to `vm/kubeconfig`. Protect both files and ensure the private key has owner-only permissions:

```sh
chmod 600 vm/rsa_4096_master.pem
```

### 4. Verify the guest cluster

```sh
terraform -chdir=vm output k8s_management_api_endpoint
terraform -chdir=vm output k8s_worker_ips

kubectl --kubeconfig=vm/kubeconfig get nodes -o wide
kubectl --kubeconfig=vm/kubeconfig get pods -A
kubectl --kubeconfig=vm/kubeconfig top nodes
```

Metrics may take time to become available. For bootstrap failures, inspect `/var/log/cloud-init-output.log` inside the affected VM and check `cloud-init status --long`.

Terraform also exposes sensitive outputs for the worker join command and shared worker console password. Retrieve them only when needed; do not put them in CI logs.

## GitHub Actions runners

The runner module creates one persistent Ubuntu VM per comma-separated registration token. The current root configuration supplies two tokens and attaches runners to VLAN 100 with DHCP.

Bootstrap installs Docker/Buildx, GitHub CLI, Git, build tools, Python, Node.js/npm, and OpenJDK 17. This is a practical CI baseline, not a replica of the GitHub-hosted runner image.

Runners need outbound access to GitHub but do not require inbound Internet ports. Only run trusted workflows on these persistent machines: jobs may access credentials, Docker, and resources reachable from the lab network.

See [runner configuration and token lifecycle](modules/github-actions-runner/README.md).

## Module documentation

- [Protected networks and migration](modules/protected-network/README.md)
- [VLAN DHCP](modules/vlan-dhcp/README.md)
- [VLAN NAT gateway](modules/vlan-nat-gateway/README.md)
- [Protected volumes and decommissioning](modules/protected-volume/README.md)
- [PVC admission protection](modules/volume-protection-policy/README.md)
- [Virtual machine abstraction](modules/virtual-machine/README.md)
- [GitHub Actions runners](modules/github-actions-runner/README.md)

The control-plane and worker module interfaces are documented in their respective `variables.tf` and `outputs.tf` files.

## Testing and CI

The [Terraform Test workflow](.github/workflows/terraform-test.yml) runs on pull requests affecting modules or the workflow itself. It discovers module directories containing `tests/`, initializes each independently, and runs `terraform test` in a matrix with Terraform 1.12.2. Failures are collected into a GitHub Actions job summary.

Run a module locally:

```sh
terraform -chdir=modules/k8s-control-plane init -backend=false
terraform -chdir=modules/k8s-control-plane validate
terraform -chdir=modules/k8s-control-plane test
```

Check formatting of the infrastructure code:

```sh
terraform fmt -check -recursive modules
terraform fmt -check -recursive fundamental
terraform fmt -check -recursive vm
```

Module tests are not proof of a successful end-to-end deployment. Live verification is still required for VLAN connectivity, image/package availability, LoadBalancer reachability, cloud-init, and admission enforcement. Review module-specific verification scripts before running them against a cluster.

## State, credentials, and lifecycle safety

- No remote backend is configured in the current roots. Protect and back up each stack's local state; use an appropriately secured, locking remote backend before collaborative operation.
- State and saved plans can contain SSH private keys, bootstrap tokens, runner registration tokens, and generated passwords. Terraform's `sensitive` flag redacts normal output; it does not encrypt state.
- Generated kubeconfigs grant administrative access. Keep them out of source control and logs.
- Preserve foundation resources when replacing compute. Review all replacement and disk-attachment changes before applying.
- Network identity is intentionally protected. VLAN/ClusterNetwork changes should use a new network and a staged migration, not in-place mutation.
- Do not use a blanket `terraform destroy` as a cleanup procedure. Follow the module decommission runbooks for protected resources.

## Known limitations

1. **Incomplete backup implementation.** `fundamental/volumes.tf` references `modules/longhorn-backup-target`, but that directory currently contains no Terraform source. Restore/implement the module, or remove the unused module block and dependent output under review, before initializing the foundation. Setting `longhorn_backup = null` does not solve source loading. `modules/cluster-manifest-backup` also has no Terraform source, and `fundamental/backup.tf` is empty. No working backup deployment should be assumed.
2. **No high availability.** There is one guest control-plane VM. DHCP and NAT are single-Pod lab services with ephemeral lease/connection state and `Recreate` updates.
3. **No automatic node scaling wired in.** The worker group is a static instance map. The `autoscaler/` source tree is not deployed by the current Terraform roots.
4. **Guest add-ons are not a separate implemented stack.** `guest-addons/` has no Terraform source. Flannel and metrics-server are currently installed by control-plane cloud-init.
5. **Bootstrap changes may recreate VMs.** Treat cloud-init changes—including add-on settings—as potentially destructive and inspect the plan. This is not an in-place Kubernetes upgrade workflow.
6. **Lab security defaults need review.** The kubeadm bootstrap token is non-expiring, workers share a generated console password, and metrics-server enables `--kubelet-insecure-tls` by default.
7. **Environment-specific inputs are embedded in code.** Network addresses, the node selector, image URLs, Kubernetes minor version, and runner registration configuration require validation for each target environment.
