output "names" {
  description = "PVC names keyed by the same stable keys supplied in var.volumes. Use this output as virtual-machine.persistent_disks[*].volume_names."
  value       = { for key, volume in harvester_volume.this : key => volume.name }
}

output "ids" {
  description = "Terraform resource IDs (namespace/name) keyed by PVC name."
  value       = { for key, volume in harvester_volume.this : key => volume.id }
}

output "storage_class_names" {
  description = "Effective StorageClass names keyed by PVC name."
  value       = { for key, volume in harvester_volume.this : key => volume.storage_class_name }
}

output "volume_modes" {
  description = "Effective Kubernetes volume modes keyed by PVC name."
  value       = { for key, volume in harvester_volume.this : key => volume.volume_mode }
}

output "access_modes" {
  description = "Effective Kubernetes access modes keyed by PVC name."
  value       = { for key, volume in harvester_volume.this : key => volume.access_mode }
}

output "declared_sizes" {
  description = "Sizes currently declared in var.volumes, keyed by PVC name. Terraform ignores changes to this field on the resource (see main.tf lifecycle.ignore_changes), so this is documentation input, not a live capacity reading."
  value       = { for key, volume in var.volumes : key => volume.size }
}

output "observed_sizes" {
  description = "Sizes last read from the provider/Kubernetes object, keyed by PVC name. Because size changes are ignored, this reflects the value at creation time or the most recent approved break-glass expansion, not necessarily var.volumes. Neither this nor declared_sizes proves the backend or guest filesystem has finished expanding."
  value       = { for key, volume in harvester_volume.this : key => volume.size }
}

output "phases" {
  description = "Observed PVC phases keyed by PVC name. A successful apply may complete before a new PVC becomes Bound."
  value       = { for key, volume in harvester_volume.this : key => volume.phase }
}
