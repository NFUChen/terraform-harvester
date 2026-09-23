terraform {
  required_version = ">= 1.3"

  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "= 1.9.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
