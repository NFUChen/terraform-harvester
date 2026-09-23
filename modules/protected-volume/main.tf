locals {
  # Module-managed labels are merged last so callers cannot disable inventory
  # identity or cluster-level delete protection.
  common_labels = merge(
    var.labels,
    {
      "app.kubernetes.io/managed-by"        = "terraform"
      "platform.harvester.io/protected"     = "true"
      "platform.harvester.io/protection-v1" = "enabled"
    }
  )

  distinct_storage_classes = toset(compact(concat(
    [var.storage_class_name],
    [for volume in values(var.volumes) : volume.storage_class_name]
  )))
}

# Fail fast at plan time if a referenced StorageClass does not exist, instead
# of only discovering it when the Kubernetes API rejects the PVC create.
data "harvester_storageclass" "referenced" {
  for_each = local.distinct_storage_classes

  name = each.key
}

resource "harvester_volume" "this" {
  for_each = var.volumes

  # The volumes map key is the PVC identity on purpose: renaming a key is a
  # different Kubernetes object, and Terraform will show it as create+destroy
  # instead of a silent in-place rename that Kubernetes does not support.
  name      = each.key
  namespace = var.namespace

  size               = each.value.size
  storage_class_name = coalesce(each.value.storage_class_name, var.storage_class_name)
  volume_mode        = coalesce(each.value.volume_mode, var.volume_mode)
  access_mode        = coalesce(each.value.access_mode, var.access_mode)
  description        = each.value.description

  labels = merge(
    each.value.labels,
    local.common_labels,
    { "app.kubernetes.io/instance" = each.key },
  )

  tags = merge(var.tags, each.value.tags)

  timeouts {
    delete = var.delete_timeout
  }

  lifecycle {
    # This is the core data-safety guarantee of this module: no plan,
    # apply, destroy, -replace, or config edit can delete a volume through
    # normal Terraform operation. See README.md "Decommissioning a volume"
    # for the only supported removal path.
    prevent_destroy = true

    # size is intentionally frozen. Terraform cannot compare a new quantity
    # against prior state inside variable validation, so a config typo could
    # otherwise shrink a PVC through an ordinary apply. Expansion is a
    # deliberate, reviewed, out-of-band change; see README.md "Expansion".
    ignore_changes = [size]
  }
}
