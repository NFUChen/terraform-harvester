locals {
  referenced_images = {
    for image in toset(compact(concat(
      [var.root_image],
      [for disk in values(var.ephemeral_disks) : disk.image],
      [for cdrom in values(var.cdroms) : cdrom.image]
      ))) : image => {
      namespace = length(split("/", image)) == 2 ? split("/", image)[0] : var.namespace
      name      = length(split("/", image)) == 2 ? split("/", image)[1] : image
    }
  }

  common_labels = merge(
    {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/name"       = var.name
    },
    var.labels
  )

  root_disk = {
    name                 = "rootdisk"
    type                 = "disk"
    size                 = var.root_disk_size
    bus                  = var.root_disk_bus
    cache_mode           = null
    boot_order           = var.root_disk_boot_order
    image                = var.root_image
    existing_volume_name = null
    container_image_name = null
    hot_plug             = false
    auto_delete          = true
    storage_class_name   = var.root_image != null ? data.harvester_image.referenced[var.root_image].volume_storage_class_name : var.root_disk_storage_class_name
    volume_mode          = null
    access_mode          = null
  }

  ephemeral_disk_list = [
    for name in sort(keys(var.ephemeral_disks)) : {
      name                 = name
      type                 = "disk"
      size                 = var.ephemeral_disks[name].size
      bus                  = var.ephemeral_disks[name].bus
      cache_mode           = var.ephemeral_disks[name].cache_mode
      boot_order           = var.ephemeral_disks[name].boot_order
      image                = var.ephemeral_disks[name].image
      existing_volume_name = null
      container_image_name = null
      hot_plug             = false
      auto_delete          = true
      storage_class_name   = var.ephemeral_disks[name].image != null ? data.harvester_image.referenced[var.ephemeral_disks[name].image].volume_storage_class_name : var.ephemeral_disks[name].storage_class_name
      volume_mode          = var.ephemeral_disks[name].volume_mode
      access_mode          = var.ephemeral_disks[name].access_mode
    }
  ]

  cdrom_list = [
    for name in sort(keys(var.cdroms)) : {
      name                 = name
      type                 = "cd-rom"
      size                 = null
      bus                  = var.cdroms[name].bus
      cache_mode           = null
      boot_order           = var.cdroms[name].boot_order
      image                = var.cdroms[name].image
      existing_volume_name = null
      container_image_name = null
      hot_plug             = false
      auto_delete          = true
      storage_class_name   = var.cdroms[name].image != null ? data.harvester_image.referenced[var.cdroms[name].image].volume_storage_class_name : null
      volume_mode          = null
      access_mode          = null
    }
  ]

  persistent_disk_list = [
    for name in sort(keys(var.persistent_disks)) : {
      name                 = name
      type                 = "disk"
      size                 = null
      bus                  = var.persistent_disks[name].bus
      cache_mode           = var.persistent_disks[name].cache_mode
      boot_order           = var.persistent_disks[name].boot_order
      image                = null
      existing_volume_name = var.persistent_disks[name].existing_volume_name
      container_image_name = null
      hot_plug             = var.persistent_disks[name].hot_plug
      auto_delete          = false
      storage_class_name   = null
      volume_mode          = null
      access_mode          = null
    }
  ]

  disks = concat(
    [local.root_disk],
    local.ephemeral_disk_list,
    local.persistent_disk_list,
    local.cdrom_list
  )

  storage_fingerprint = sha256(jsonencode({
    root_disk        = local.root_disk
    ephemeral_disks  = local.ephemeral_disk_list
    persistent_disks = local.persistent_disk_list
    cdroms           = local.cdrom_list
  }))

  # The VM's cloudinit block only references a static Secret name, so editing
  # the payload updates harvester_cloudinit_secret in place and leaves the VM
  # untouched. A guest only reads cloud-init on first boot, making that
  # in-place update a no-op for the running VM. Hash the effective cloud-init
  # config so any real change replaces the VM instead. The value is a digest,
  # so cloud-init content is never duplicated into the trigger's plan output.
  cloudinit_fingerprint = sha256(jsonencode({
    enabled      = var.cloudinit.enabled
    type         = var.cloudinit.type
    user_data    = var.cloudinit.user_data
    network_data = var.cloudinit.network_data
  }))
}

data "harvester_image" "referenced" {
  for_each = local.referenced_images

  name      = each.value.name
  namespace = each.value.namespace
}

resource "terraform_data" "storage_topology" {
  input = local.storage_fingerprint
}

resource "terraform_data" "cloudinit_configuration" {
  input = local.cloudinit_fingerprint
}

resource "harvester_cloudinit_secret" "this" {
  count = var.cloudinit.enabled ? 1 : 0

  name         = "${var.name}-cloudinit"
  namespace    = var.namespace
  description  = "Cloud-init configuration for ${var.name}. Managed by Terraform."
  user_data    = var.cloudinit.user_data
  network_data = var.cloudinit.network_data

  labels = merge(local.common_labels, {
    "app.kubernetes.io/instance" = var.name
  })
}

resource "harvester_virtualmachine" "this" {
  name        = var.name
  namespace   = var.namespace
  description = var.description

  labels = merge(local.common_labels, {
    "app.kubernetes.io/instance" = var.name
  })
  tags = var.tags

  hostname = var.set_hostname_from_instance_name ? var.name : null

  cpu             = var.cpu
  cpu_model       = var.cpu_model
  memory          = var.memory
  machine_type    = var.machine_type
  reserved_memory = var.reserved_memory

  cpu_pinning             = var.cpu_pinning
  isolate_emulator_thread = var.isolate_emulator_thread
  node_selector           = var.node_selector

  efi         = var.efi
  secure_boot = var.secure_boot

  run_strategy            = var.run_strategy
  restart_after_update    = var.restart_after_update
  create_initial_snapshot = var.create_initial_snapshot

  ssh_keys = var.ssh_keys

  dynamic "requests" {
    for_each = var.resource_requests == null ? [] : [var.resource_requests]

    content {
      cpu    = requests.value.cpu
      memory = requests.value.memory
    }
  }

  dynamic "network_interface" {
    for_each = var.network_interfaces

    content {
      name           = network_interface.value.name
      network_name   = network_interface.value.network_name
      type           = network_interface.value.type
      model          = network_interface.value.model
      mac_address    = network_interface.value.mac_address
      wait_for_lease = network_interface.value.wait_for_lease
      boot_order     = network_interface.value.boot_order
    }
  }

  dynamic "disk" {
    for_each = local.disks

    content {
      name                 = disk.value.name
      type                 = disk.value.type
      size                 = disk.value.size
      bus                  = disk.value.bus
      cache_mode           = disk.value.cache_mode
      boot_order           = disk.value.boot_order
      image                = disk.value.image
      existing_volume_name = disk.value.existing_volume_name
      container_image_name = disk.value.container_image_name
      hot_plug             = disk.value.hot_plug
      auto_delete          = disk.value.auto_delete
      storage_class_name   = disk.value.storage_class_name
      volume_mode          = disk.value.volume_mode
      access_mode          = disk.value.access_mode
    }
  }

  dynamic "cloudinit" {
    for_each = var.cloudinit.enabled ? [1] : []

    content {
      type                     = var.cloudinit.type
      user_data_secret_name    = harvester_cloudinit_secret.this[0].name
      network_data_secret_name = harvester_cloudinit_secret.this[0].name
    }
  }

  dynamic "input" {
    for_each = var.inputs

    content {
      name = input.value.name
      type = input.value.type
      bus  = input.value.bus
    }
  }

  dynamic "host_device" {
    for_each = var.host_devices

    content {
      name        = host_device.value.name
      device_name = host_device.value.device_name
    }
  }

  dynamic "tpm" {
    for_each = var.tpm ? [1] : []

    content {}
  }

  timeouts {
    create = var.timeouts.create
    read   = var.timeouts.read
    update = var.timeouts.update
    delete = var.timeouts.delete
  }

  lifecycle {
    # Provider 1.9.0's importer reads the cloud-init disk (cloudinitdisk) that
    # Harvester's own builder creates from the `cloudinit` block back into the
    # `disk` list. Config here only declares `cloudinit`, so every read/plan
    # shows a permanent phantom diff removing that entry. Ignoring `disk`
    # drift is safe because every disk field the caller can actually set
    # (root/ephemeral/persistent/cdrom) is already covered by
    # storage_fingerprint below; any real storage change still
    # replaces the VM through replace_triggered_by.
    ignore_changes = [disk]

    replace_triggered_by = [
      terraform_data.storage_topology,
      terraform_data.cloudinit_configuration,
    ]

    precondition {
      condition     = !var.secure_boot || var.efi
      error_message = "secure_boot requires efi = true."
    }

    precondition {
      condition     = !var.isolate_emulator_thread || var.cpu_pinning
      error_message = "isolate_emulator_thread requires cpu_pinning = true."
    }

    precondition {
      condition     = var.root_image == null || var.root_disk_storage_class_name == null
      error_message = "root_disk_storage_class_name must be omitted when root_image is set; the image determines its storage class."
    }

    precondition {
      condition     = var.cloudinit.enabled || length(var.ssh_keys) == 0
      error_message = "ssh_keys require cloudinit.enabled = true."
    }

    precondition {
      condition = length(setintersection(
        toset(keys(var.ephemeral_disks)),
        toset(keys(var.persistent_disks))
        )) == 0 && length(setintersection(
        toset(keys(var.ephemeral_disks)),
        toset(keys(var.cdroms))
        )) == 0 && length(setintersection(
        toset(keys(var.persistent_disks)),
        toset(keys(var.cdroms))
      )) == 0
      error_message = "Disk names must be unique across ephemeral_disks, persistent_disks, and cdroms."
    }
  }
}
