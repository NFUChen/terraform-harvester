terraform {
  required_version = ">= 1.3"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

# This stack targets the GUEST kubeadm cluster, not Harvester. It is applied
# after the vm/ stack has exported the guest kubeconfig, so provider
# configuration never depends on a file produced during its own apply.
provider "kubernetes" {
  config_path    = var.kubeconfig
  config_context = var.kubecontext
}
