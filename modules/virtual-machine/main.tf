locals {
  instance_names = [
    for index in range(var.instance_count) : format("%s-%02d", var.name_prefix, index + 1)
  ]

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
      "app.kubernetes.io/name"       = var.name_prefix
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

  persistent_disks_by_instance = {
    for instance_name in local.instance_names : instance_name => [
      for name in sort(keys(var.persistent_disks)) : {
        name                 = name
        type                 = "disk"
        size                 = null
        bus                  = var.persistent_disks[name].bus
        cache_mode           = var.persistent_disks[name].cache_mode
        boot_order           = var.persistent_disks[name].boot_order
        image                = null
        existing_volume_name = lookup(var.persistent_disks[name].volume_names, instance_name, null)
        container_image_name = null
        hot_plug             = var.persistent_disks[name].hot_plug
        auto_delete          = false
        storage_class_name   = null
        volume_mode          = null
        access_mode          = null
      }
    ]
  }

  disks_by_instance = {
    for instance_name in local.instance_names : instance_name => concat(
      [local.root_disk],
      local.ephemeral_disk_list,
      local.persistent_disks_by_instance[instance_name],
      local.cdrom_list
    )
  }

  storage_fingerprint_by_instance = {
    for instance_name in local.instance_names : instance_name => sha256(jsonencode({
      root_disk        = local.root_disk
      ephemeral_disks  = local.ephemeral_disk_list
      persistent_disks = local.persistent_disks_by_instance[instance_name]
      cdroms           = local.cdrom_list
    }))
  }
}

data "harvester_image" "referenced" {
  for_each = local.referenced_images

  name      = each.value.name
  namespace = each.value.namespace
}

resource "terraform_data" "storage_topology" {
  for_each = toset(local.instance_names)

  input = local.storage_fingerprint_by_instance[each.key]
}

resource "harvester_cloudinit_secret" "this" {
  for_each = var.cloudinit.enabled ? toset(local.instance_names) : toset([])

  name         = "${each.key}-cloudinit"
  namespace    = var.namespace
  description  = "Cloud-init configuration for ${each.key}. Managed by Terraform."
  user_data    = var.cloudinit.user_data
  network_data = var.cloudinit.network_data

  labels = merge(local.common_labels, {
    "app.kubernetes.io/instance" = each.key
  })
}

resource "harvester_virtualmachine" "this" {
  for_each = toset(local.instance_names)

  name        = each.key
  namespace   = var.namespace
  description = var.description

  labels = merge(local.common_labels, {
    "app.kubernetes.io/instance" = each.key
  })
  tags = var.tags

  hostname = var.set_hostname_from_instance_name ? each.key : null

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
    for_each = local.disks_by_instance[each.key]

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
      user_data_secret_name    = harvester_cloudinit_secret.this[each.key].name
      network_data_secret_name = harvester_cloudinit_secret.this[each.key].name
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
    # storage_fingerprint_by_instance below; any real storage change still
    # replaces the VM through replace_triggered_by.
    ignore_changes = [disk]

    replace_triggered_by = [
      terraform_data.storage_topology[each.key],
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
      condition = alltrue([
        for disk in values(var.persistent_disks) :
        contains(keys(disk.volume_names), each.key)
      ])
      error_message = "Every persistent disk must provide an existing PVC name for every VM instance."
    }

    precondition {
      condition = length([
        for disk in values(var.persistent_disks) : disk.volume_names[each.key]
        if contains(keys(disk.volume_names), each.key)
        ]) == length(toset([
          for disk in values(var.persistent_disks) : disk.volume_names[each.key]
          if contains(keys(disk.volume_names), each.key)
      ]))
      error_message = "A VM cannot attach the same persistent PVC under multiple disk names."
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
