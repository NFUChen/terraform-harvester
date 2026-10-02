# Harvester Terraform Modules

Reusable Terraform modules for an existing Harvester cluster: VLAN networking, protected data volumes, virtual machines, kubeadm-based Kubernetes nodes, and persistent GitHub Actions runners.

Use the modules independently or compose them in your own Terraform root configuration. The caller owns environment-specific choices such as provider credentials, state backends, image selection, network topology, and resource sizing. This repository is a module library, not a one-command deployment or a Harvester installer.

## Module catalog

### Networking

| Module | Purpose |
| --- | --- |
| [protected-network](modules/protected-network/README.md) | Create long-lived VLAN networks on an existing ClusterNetwork, with optional per-network DHCP and NAT services. Network identity is protected; topology changes use a new network and staged migration. |
| [vlan-dhcp](modules/vlan-dhcp/README.md) | Run a dnsmasq DHCP service on an existing VLAN network. Configure the address pool, gateway, DNS servers, and node placement. |
| [vlan-nat-gateway](modules/vlan-nat-gateway/README.md) | Provide outbound IPv4 NAT for a VLAN through a gateway Pod on the Harvester management cluster. |

### Storage and protection

| Module | Purpose |
| --- | --- |
| [protected-volume](modules/protected-volume/README.md) | Create independently managed, empty data PVCs with protection labels, Terraform destruction guards, and frozen size updates. Volumes are owned separately from VMs. |
| [volume-protection-policy](modules/volume-protection-policy/README.md) | Install cluster-scoped admission protection against deletion of labeled PVCs and removal of their protection label, with explicitly configured emergency identities. |

### Compute and guest workloads

| Module | Purpose |
| --- | --- |
| [virtual-machine](modules/virtual-machine/README.md) | Create a single Harvester VM with configurable compute, placement, firmware, network interfaces, VM-owned disks, existing persistent PVC attachments, and cloud-init. |
| [k8s-control-plane](modules/k8s-control-plane) | Bootstrap a single kubeadm control-plane VM with containerd, Flannel, optional metrics-server, a management-facing Harvester LoadBalancer, and optional local kubeconfig export. |
| [k8s-worker-group](modules/k8s-worker-group) | Bootstrap a static map of kubeadm worker VMs, with optional existing data-volume attachments and guest filesystem mounts. |
| [github-actions-runner](modules/github-actions-runner/README.md) | Create persistent Ubuntu x86_64 self-hosted runner VMs for a GitHub repository or organization, one per supplied registration token. |

Each module's `variables.tf` and `outputs.tf` define its interface. For the Kubernetes modules, see the control-plane [inputs](modules/k8s-control-plane/variables.tf) and [outputs](modules/k8s-control-plane/outputs.tf), and worker-group [inputs](modules/k8s-worker-group/variables.tf) and [outputs](modules/k8s-worker-group/outputs.tf). The admission-policy module defines its outputs in [main.tf](modules/volume-protection-policy/main.tf).

## How the modules fit together

Internal module composition:

```text
protected-network
├── vlan-dhcp                 optional, per network
└── vlan-nat-gateway          optional, per network

k8s-control-plane ──┐
k8s-worker-group ───┼── virtual-machine
github-actions-runner ─┘

protected-volume             independent data-volume ownership
volume-protection-policy     separately managed cluster protection
```

The higher-level compute modules reuse `virtual-machine`; they do not require you to create an additional VM module yourself. DHCP and NAT can also be used independently with an existing network.

Compose resources through their interfaces:

- **Network → VM:** `protected-network.ids[key]` supplies the namespace-qualified network reference (`namespace/name`).
- **Volume → VM:** `protected-volume.names[key]` supplies `persistent_disks.<device>.existing_volume_name`. This is a PVC name, not a namespace-qualified ID; the VM and PVC must share a namespace.
- **Control plane → workers:** pass `worker_join_command` and `cluster_generation` into the worker group's `join_command` and `cluster_generation`. The generation value tracks bootstrap configuration, not live cluster readiness.
- **Policy → volumes:** deploy `volume-protection-policy` separately, preferably from independently controlled state before creating protected PVCs. The volume module does not install or verify the policy.

Keep long-lived networks and data volumes independent of replaceable compute. Whether these live in one state or separate states is a caller decision; separate states require an explicit resource-discovery or output-sharing strategy.

## Requirements

- An existing, reachable Harvester cluster and credentials with permissions for the resources managed by the selected modules.
- **Terraform 1.12.2 recommended**, matching CI. Although module declarations currently say `>= 1.3`, some implementation features require newer releases; do not treat 1.3 as a universal supported minimum.
- Existing namespaces, ready VM images, StorageClasses, and ClusterNetworks/uplinks as required by the selected modules.
- For VLAN services, an eligible node carrying the VLAN and permissions for the required network capabilities; NAT also uses a privileged init container.
- For admission protection, an API supporting `admissionregistration.k8s.io/v1` `ValidatingAdmissionPolicy` and `ValidatingAdmissionPolicyBinding`, plus cluster-scoped administration permissions.
- For guest bootstrap, outbound access to the relevant package repositories and release artifacts. Control-plane kubeconfig export additionally requires local Bash, OpenSSH, Python 3, and `kubectl`.

Configure providers in your calling root module:

| Provider | Constraint | Used by |
| --- | --- | --- |
| `harvester/harvester` | `= 1.9.0` | Protected networks and volumes, VM and higher-level compute modules |
| `hashicorp/kubernetes` | `~> 2.38` | Protected networks, DHCP, NAT, and admission policy |
| `hashicorp/random` | `~> 3.6` | Kubernetes control-plane and worker-group modules |

Only configure the providers needed by your chosen modules. Both the Harvester provider and the Kubernetes provider used by these modules target the **Harvester management cluster**, not the guest Kubernetes cluster created inside VMs.

## Using a module

Create your own Terraform root configuration and reference the desired module directory. The following module block assumes a caller located alongside a checkout named `harvester`; adjust `source` to your checkout location. Configure the Harvester provider in that caller before planning.

```hcl
module "data" {
  source = "../harvester/modules/protected-volume"

  namespace          = "default"
  storage_class_name = "harvester-longhorn"

  volumes = {
    "application-data" = {
      size = "100Gi"
    }
  }
}
```

The namespace and StorageClass must already exist; use your environment's actual names. This creates an empty PVC with the module defaults of `Block` mode and `ReadWriteOnce` access. It does not attach, format, or back up the volume, or install API-level deletion protection.

To attach it to a separately configured `virtual-machine` module in the same namespace, include this argument in that VM's module block:

```hcl
persistent_disks = {
  data = {
    existing_volume_name = module.data.names["application-data"]
  }
}
```

Guest partitioning, formatting, and mounting are separate from attaching a disk. See the [VM documentation](modules/virtual-machine/README.md) for a complete VM configuration and the [volume runbook](modules/protected-volume/README.md) for expansion, migration, and decommissioning.

From your own root configuration, initialize and review the plan before applying:

```sh
terraform init
terraform validate
terraform plan -out=deployment.tfplan
terraform apply deployment.tfplan
```

These commands are for your calling configuration, not a repository-wide deployment entry point. Protect the state and saved plan as sensitive artifacts.

## Lifecycle and operational boundaries

### Protection is not backup

Terraform destruction guards only work while the relevant configuration remains present; they do not prevent direct API deletion. Admission protection adds a separate enforcement layer, but its policy, binding, and emergency identities must themselves be secured. Neither layer provides backups.

Protected networks deliberately ignore subsequent configuration changes. Protected volumes ignore size changes, including requested growth. Use their documented migration and expansion procedures, and distinguish declared configuration from observed resource outputs.

### VM ownership matters

VM-owned root and ephemeral disks are disposable. Existing persistent PVCs are attached without transferring ownership to the VM. Storage attachment and cloud-init changes can trigger VM replacement; inspect plans before applying and verify data retention independently.

Volume creation is not proof that a PVC is ready for attachment. An access mode such as `ReadWriteMany` also does not make an ordinary guest filesystem safe for concurrent writers. Review worker mount configuration carefully: bootstrap can format a selected device when no filesystem is detected.

### Workload modules are not managed platforms

- DHCP and NAT are single-replica lab/sandbox services with `Recreate` updates and ephemeral lease or connection state, not highly available network appliances.
- NAT supplies neither DNS nor a default-deny security firewall. Configure explicit DNS resolvers when pairing it with standalone DHCP, whose default assumes the gateway serves DNS.
- The Kubernetes control plane is a single VM. Worker groups are static, and bootstrap changes can rebuild VMs rather than perform rolling cluster upgrades.
- Review bootstrap security settings before production use, including join-command CA verification, shared worker console credentials, and metrics-server's insecure kubelet TLS default.
- GitHub Actions runners are persistent machines intended for trusted workflows. Isolate their credentials and network access, and account for registration-token expiry and VM replacement behavior.

### Credentials and readiness

Terraform state, saved plans, and cloud-init data can contain credentials. Sensitive output redaction is not encryption, and not every credential-bearing input is marked sensitive. Secure state storage, restrict access to generated kubeconfigs, and keep secrets out of source control and logs.

Successful Terraform operations and mocked tests do not prove guest readiness. Validate networking, cloud-init completion, cluster joins, storage retention, and admission enforcement against your target environment.

## Testing and CI

The [Terraform Test workflow](.github/workflows/terraform-test.yml) discovers module directories containing `tests/` and runs them independently in a matrix using Terraform 1.12.2. It triggers on pull requests changing modules or the workflow itself.

Run a module's checks locally:

```sh
terraform -chdir=modules/virtual-machine init -backend=false
terraform -chdir=modules/virtual-machine validate
terraform -chdir=modules/virtual-machine test
```

Check formatting across the module library:

```sh
terraform fmt -check -recursive modules
```

The tests use mocked providers and exercise configuration behavior, not a live Harvester deployment. Review module-specific verification scripts before running them against a cluster.
