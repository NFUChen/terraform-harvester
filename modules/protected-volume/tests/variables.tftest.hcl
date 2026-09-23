mock_provider "harvester" {
  mock_data "harvester_storageclass" {
    defaults = {
      allow_volume_expansion = true
      name                   = "mock-storage-class"
    }
  }
}

run "minimal_valid_call" {
  command = plan

  variables {
    storage_class_name = "harvester-longhorn"

    volumes = {
      "web-01-data" = {
        size = "100Gi"
      }
    }
  }

  assert {
    condition     = harvester_volume.this["web-01-data"].name == "web-01-data"
    error_message = "The volumes map key must be the exact PVC name."
  }

  assert {
    condition     = harvester_volume.this["web-01-data"].storage_class_name == "harvester-longhorn"
    error_message = "The module default StorageClass must be applied."
  }

  assert {
    condition     = harvester_volume.this["web-01-data"].volume_mode == "Block"
    error_message = "The safe default volume mode must be Block."
  }

  assert {
    condition     = harvester_volume.this["web-01-data"].access_mode == "ReadWriteOnce"
    error_message = "The safe default access mode must be ReadWriteOnce."
  }

  assert {
    condition     = output.names["web-01-data"] == "web-01-data"
    error_message = "The names output must integrate directly with virtual-machine persistent_disks volume_names."
  }

  assert {
    condition     = output.storage_class_names["web-01-data"] == "harvester-longhorn"
    error_message = "The effective StorageClass must be visible as an output."
  }

  assert {
    condition     = output.volume_modes["web-01-data"] == "Block" && output.access_modes["web-01-data"] == "ReadWriteOnce"
    error_message = "The effective volume/access modes must be visible as outputs."
  }
}

run "invalid_pvc_name_rejected" {
  command = plan

  variables {
    storage_class_name = "harvester-longhorn"

    volumes = {
      "Web_01_Data" = {
        size = "100Gi"
      }
    }
  }

  expect_failures = [
    var.volumes,
  ]
}

run "invalid_size_quantity_rejected" {
  command = plan

  variables {
    storage_class_name = "harvester-longhorn"

    volumes = {
      "web-01-data" = {
        size = "one hundred gigs"
      }
    }
  }

  expect_failures = [
    var.volumes,
  ]
}

run "invalid_volume_mode_rejected" {
  command = plan

  variables {
    storage_class_name = "harvester-longhorn"

    volumes = {
      "web-01-data" = {
        size        = "100Gi"
        volume_mode = "Weird"
      }
    }
  }

  expect_failures = [
    var.volumes,
  ]
}

run "invalid_access_mode_rejected" {
  command = plan

  variables {
    storage_class_name = "harvester-longhorn"

    volumes = {
      "web-01-data" = {
        size        = "100Gi"
        access_mode = "WriteOnlyForever"
      }
    }
  }

  expect_failures = [
    var.volumes,
  ]
}

run "empty_default_storage_class_rejected" {
  command = plan

  variables {
    storage_class_name = ""

    volumes = {
      "web-01-data" = {
        size = "100Gi"
      }
    }
  }

  expect_failures = [
    var.storage_class_name,
  ]
}

run "per_volume_storage_class_override_allowed" {
  command = plan

  variables {
    storage_class_name = "harvester-longhorn"

    volumes = {
      "web-01-data" = {
        size               = "100Gi"
        storage_class_name = "harvester-longhorn-ssd"
        volume_mode        = "Filesystem"
        access_mode        = "ReadOnlyMany"
      }
    }
  }

  assert {
    condition     = harvester_volume.this["web-01-data"].storage_class_name == "harvester-longhorn-ssd"
    error_message = "The per-volume StorageClass override must win."
  }

  assert {
    condition     = harvester_volume.this["web-01-data"].volume_mode == "Filesystem"
    error_message = "The per-volume volume mode override must win."
  }

  assert {
    condition     = harvester_volume.this["web-01-data"].access_mode == "ReadOnlyMany"
    error_message = "The per-volume access mode override must win."
  }
}

run "dns_label_over_63_chars_rejected" {
  command = plan

  variables {
    storage_class_name = "harvester-longhorn"

    volumes = {
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-data" = {
        size = "10Gi"
      }
    }
  }

  expect_failures = [
    var.volumes,
  ]
}

run "storage_class_over_253_chars_rejected" {
  command = plan

  variables {
    storage_class_name = join(".", [for i in range(5) : "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])

    volumes = {
      "web-01-data" = {
        size = "10Gi"
      }
    }
  }

  expect_failures = [
    var.storage_class_name,
  ]
}

run "dns_name_with_empty_label_rejected" {
  command = plan

  variables {
    storage_class_name = "harvester-longhorn"

    volumes = {
      "web..data" = {
        size = "10Gi"
      }
    }
  }

  expect_failures = [
    var.volumes,
  ]
}

run "caller_cannot_remove_protection_label" {
  command = plan

  variables {
    storage_class_name = "harvester-longhorn"

    volumes = {
      "web-01-data" = {
        size = "100Gi"
        labels = {
          "platform.harvester.io/protected" = "false"
        }
      }
    }
  }

  assert {
    condition     = harvester_volume.this["web-01-data"].labels["platform.harvester.io/protected"] == "true"
    error_message = "A caller-supplied label must never be able to override the module's protection label."
  }
}

run "empty_volumes_map_rejected" {
  command = plan

  variables {
    storage_class_name = "harvester-longhorn"
    volumes            = {}
  }

  expect_failures = [
    var.volumes,
  ]
}
