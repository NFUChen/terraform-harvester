terraform {
  required_version = ">= 1.0"

  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "= 1.9.0"
    }
  }
}

provider "harvester" {
  kubeconfig  = var.kubeconfig
  kubecontext = var.kubecontext
}
