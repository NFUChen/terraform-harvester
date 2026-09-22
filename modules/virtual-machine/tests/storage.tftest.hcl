mock_provider "harvester" {}

run "safe_storage_topology" {
  command = plan

  variables {
    name_prefix    = "test"
    instance_count = 2
    root_image     = null
    cloudinit = {
      enabled = false
    }

    ephemeral_disks = {
      cache = {
        size = "20Gi"
      }
    }

    persistent_disks = {
      data = {
        volume_names = {
          test-01 = "test-01-data"
          test-02 = "test-02-data"
        }
      }
    }

    cdroms = {
      installer = {}
    }
  }

  assert {
    condition     = alltrue([for vm in harvester_virtualmachine.this : length(vm.disk) == 4])
    error_message = "Each VM must have root, ephemeral, persistent, and CD-ROM disks."
  }

  assert {
    condition = alltrue(flatten([
      for vm in harvester_virtualmachine.this : [
        for disk in vm.disk : disk.name != "cache" || disk.auto_delete
      ]
    ]))
    error_message = "Ephemeral disks must always be auto-deleted."
  }

  assert {
    condition = alltrue(flatten([
      for vm in harvester_virtualmachine.this : [
        for disk in vm.disk : disk.name != "data" || !disk.auto_delete
      ]
    ]))
    error_message = "Persistent disks must never be auto-deleted."
  }

  assert {
    condition = alltrue([
      for name, vm in harvester_virtualmachine.this :
      one([for disk in vm.disk : disk.existing_volume_name if disk.name == "data"]) == "${name}-data"
    ])
    error_message = "Each VM must attach its own persistent PVC."
  }

  assert {
    condition = alltrue(flatten([
      for vm in harvester_virtualmachine.this : [
        for disk in vm.disk : disk.name != "installer" || disk.type == "cd-rom"
      ]
    ]))
    error_message = "CD-ROM entries must render as cd-rom disks."
  }
}

run "reserved_ephemeral_name_rejected" {
  command = plan

  variables {
    name_prefix = "test"
    root_image  = null
    cloudinit = {
      enabled = false
    }

    ephemeral_disks = {
      rootdisk = {
        size = "20Gi"
      }
    }
  }

  expect_failures = [
    var.ephemeral_disks,
  ]
}

run "missing_persistent_volume_mapping_rejected" {
  command = plan

  variables {
    name_prefix    = "test"
    instance_count = 2
    root_image     = null
    cloudinit = {
      enabled = false
    }

    persistent_disks = {
      data = {
        volume_names = {
          test-01 = "test-01-data"
        }
      }
    }
  }

  expect_failures = [
    harvester_virtualmachine.this,
  ]
}

run "empty_persistent_volume_name_rejected" {
  command = plan

  variables {
    name_prefix = "test"
    root_image  = null
    cloudinit = {
      enabled = false
    }

    persistent_disks = {
      data = {
        volume_names = {
          test-01 = ""
        }
      }
    }
  }

  expect_failures = [
    var.persistent_disks,
  ]
}

run "duplicate_persistent_volume_on_one_vm_rejected" {
  command = plan

  variables {
    name_prefix = "test"
    root_image  = null
    cloudinit = {
      enabled = false
    }

    persistent_disks = {
      data = {
        volume_names = {
          test-01 = "test-01-shared"
        }
      }
      logs = {
        volume_names = {
          test-01 = "test-01-shared"
        }
      }
    }
  }

  expect_failures = [
    harvester_virtualmachine.this,
  ]
}

run "cross_category_disk_name_collision_rejected" {
  command = plan

  variables {
    name_prefix = "test"
    root_image  = null
    cloudinit = {
      enabled = false
    }

    ephemeral_disks = {
      data = {
        size = "20Gi"
      }
    }

    cdroms = {
      data = {}
    }
  }

  expect_failures = [
    harvester_virtualmachine.this,
  ]
}
