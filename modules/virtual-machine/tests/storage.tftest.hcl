mock_provider "harvester" {}

run "single_vm_name" {
  command = plan

  variables {
    name       = "worker-blue"
    root_image = null
    cloudinit = {
      enabled = false
    }
  }

  assert {
    condition     = harvester_virtualmachine.this.name == "worker-blue"
    error_message = "The singleton VM must use the exact caller-provided name."
  }

  assert {
    condition     = output.cloudinit_secret_name == null
    error_message = "Disabled cloud-init must not index a missing secret and must output null."
  }
}

run "safe_storage_topology" {
  command = plan

  variables {
    name       = "test-01"
    root_image = null
    cloudinit = {
      enabled = false
    }

    ephemeral_disks = {
      cache = { size = "20Gi" }
    }

    persistent_disks = {
      data = { existing_volume_name = "test-01-data" }
    }

    cdroms = {
      installer = {}
    }
  }

  assert {
    condition     = length(harvester_virtualmachine.this.disk) == 4
    error_message = "The VM must have root, ephemeral, persistent, and CD-ROM disks."
  }

  assert {
    condition = local.storage_fingerprint == sha256(jsonencode({
      root_disk        = local.root_disk
      ephemeral_disks  = local.ephemeral_disk_list
      persistent_disks = local.persistent_disk_list
      cdroms           = local.cdrom_list
    }))
    error_message = "The replacement fingerprint must cover every caller-configurable disk category."
  }

  assert {
    condition = local.storage_fingerprint != sha256(jsonencode({
      root_disk        = merge(local.root_disk, { size = "999Gi" })
      ephemeral_disks  = local.ephemeral_disk_list
      persistent_disks = local.persistent_disk_list
      cdroms           = local.cdrom_list
    }))
    error_message = "A root disk change must alter the replacement fingerprint."
  }

  assert {
    condition     = one([for disk in harvester_virtualmachine.this.disk : disk.auto_delete if disk.name == "cache"])
    error_message = "Ephemeral disks must always be auto-deleted."
  }

  assert {
    condition     = !one([for disk in harvester_virtualmachine.this.disk : disk.auto_delete if disk.name == "data"])
    error_message = "Persistent disks must never be auto-deleted."
  }

  assert {
    condition     = one([for disk in harvester_virtualmachine.this.disk : disk.existing_volume_name if disk.name == "data"]) == "test-01-data"
    error_message = "The VM must attach the configured persistent PVC."
  }

  assert {
    condition     = one([for disk in harvester_virtualmachine.this.disk : disk.type if disk.name == "installer"]) == "cd-rom"
    error_message = "CD-ROM entries must render as cd-rom disks."
  }
}

run "reserved_ephemeral_name_rejected" {
  command = plan
  variables {
    name       = "test"
    root_image = null
    cloudinit  = { enabled = false }
    ephemeral_disks = {
      rootdisk = { size = "20Gi" }
    }
  }
  expect_failures = [var.ephemeral_disks]
}

run "empty_persistent_volume_name_rejected" {
  command = plan
  variables {
    name       = "test"
    root_image = null
    cloudinit  = { enabled = false }
    persistent_disks = {
      data = { existing_volume_name = "" }
    }
  }
  expect_failures = [var.persistent_disks]
}

run "duplicate_persistent_volume_rejected" {
  command = plan
  variables {
    name       = "test"
    root_image = null
    cloudinit  = { enabled = false }
    persistent_disks = {
      data = { existing_volume_name = "test-shared" }
      logs = { existing_volume_name = "test-shared" }
    }
  }
  expect_failures = [var.persistent_disks]
}

run "cross_category_disk_name_collision_rejected" {
  command = plan
  variables {
    name       = "test"
    root_image = null
    cloudinit  = { enabled = false }
    ephemeral_disks = {
      data = { size = "20Gi" }
    }
    cdroms = { data = {} }
  }
  expect_failures = [harvester_virtualmachine.this]
}
