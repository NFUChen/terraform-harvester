mock_provider "harvester" {}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = {
      result      = "MockWorkerPassword-123!"
      bcrypt_hash = "$2a$10$mockedWorkerPasswordHash"
    }
  }
}

variables {
  instances = {
    k8s-worker-01 = {
      address = "172.16.100.20/24"
      cpu     = 4
      memory  = "8Gi"
    }
    k8s-worker-02 = { address = "172.16.100.21/24" }
    k8s-worker-03 = { address = "172.16.100.22/24" }
  }

  cpu        = 2
  memory     = "4Gi"
  root_image = "harvester-public/ubuntu"

  network = {
    name    = "harvester-public/v100"
    gateway = "172.16.100.1"
  }

  cluster_generation = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  join_command       = "kubeadm join 172.16.100.10:6443 --token abcdef.0123456789abcdef --discovery-token-unsafe-skip-ca-verification"
}

run "three_worker_group" {
  command = plan

  assert {
    condition     = sort(keys(module.worker)) == tolist(["k8s-worker-01", "k8s-worker-02", "k8s-worker-03"])
    error_message = "The group must create exactly the named workers."
  }

  assert {
    condition     = alltrue([for name, worker in module.worker : worker.name == name])
    error_message = "Each singleton VM module must use its map key as the exact worker name."
  }

  assert {
    condition     = alltrue([for worker in module.worker : length(worker.network_interfaces) == 2])
    error_message = "Every worker must have management and cluster interfaces."
  }

  assert {
    condition     = alltrue([for worker in module.worker : worker.run_strategy == "Always"])
    error_message = "Every worker VM must restart automatically with the Always run strategy."
  }

  assert {
    condition     = strcontains(file("${path.module}/userdata.yaml"), "[systemctl, enable, kubelet]")
    error_message = "Worker cloud-init must enable kubelet so it starts after a VM reboot."
  }

  assert {
    condition     = output.worker_ips["k8s-worker-01"] == "172.16.100.20" && output.worker_ips["k8s-worker-03"] == "172.16.100.22"
    error_message = "Each worker name must remain bound to its configured static IP."
  }

  assert {
    condition = (
      module.worker["k8s-worker-01"].cpu == 4 &&
      module.worker["k8s-worker-01"].memory == "8Gi"
    )
    error_message = "A per-instance compute override must size only that worker."
  }

  assert {
    condition = alltrue([
      for name in ["k8s-worker-02", "k8s-worker-03"] :
      module.worker[name].cpu == 2 &&
      module.worker[name].memory == "4Gi"
    ])
    error_message = "Workers without an override must inherit the group defaults."
  }

}

run "duplicate_volume_attachment_rejected" {
  command = plan

  variables {
    instances = {
      k8s-worker-01 = {
        address = "172.16.100.20/24"
        persistent_disks = {
          data = { existing_volume_name = "app-data" }
        }
      }
      k8s-worker-02 = {
        address = "172.16.100.21/24"
        persistent_disks = {
          data = { existing_volume_name = "app-data" }
        }
      }
    }
  }

  expect_failures = [var.instances]
}

run "partial_mount_settings_rejected" {
  command = plan

  variables {
    instances = {
      k8s-worker-01 = {
        address = "172.16.100.20/24"
        persistent_disks = {
          appdata = {
            existing_volume_name = "app-data"
            mount_path           = "/mnt/app-data"
          }
        }
      }
    }
  }

  expect_failures = [var.instances]
}

run "unsupported_filesystem_rejected" {
  command = plan

  variables {
    instances = {
      k8s-worker-01 = {
        address = "172.16.100.20/24"
        persistent_disks = {
          appdata = {
            existing_volume_name = "app-data"
            device               = "/dev/vdb"
            filesystem           = "btrfs"
            mount_path           = "/mnt/app-data"
          }
        }
      }
    }
  }

  expect_failures = [var.instances]
}

run "invalid_instance_cpu_rejected" {
  command = plan

  variables {
    instances = {
      k8s-worker-01 = {
        address = "172.16.100.20/24"
        cpu     = 0
      }
    }
  }

  expect_failures = [var.instances]
}

run "invalid_instance_memory_rejected" {
  command = plan

  variables {
    instances = {
      k8s-worker-01 = {
        address = "172.16.100.20/24"
        memory  = "lots"
      }
    }
  }

  expect_failures = [var.instances]
}

run "duplicate_worker_addresses_rejected" {
  command = plan

  variables {
    instances = {
      k8s-worker-01 = {
        address = "172.16.100.20/24"
        persistent_disks = {
          appdata = { existing_volume_name = "app-data" }
        }
      }
      k8s-worker-02 = { address = "172.16.100.20/24" }
    }
  }

  expect_failures = [var.instances]
}
