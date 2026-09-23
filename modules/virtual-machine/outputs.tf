output "name" {
  description = "Name of the VM."
  value       = harvester_virtualmachine.this.name
}

output "id" {
  description = "Terraform resource ID (namespace/name)."
  value       = harvester_virtualmachine.this.id
}

output "node_name" {
  description = "Harvester node currently running the VM. Empty until the VM is scheduled."
  value       = harvester_virtualmachine.this.node_name
}

output "state" {
  description = "Terraform-derived VM state (Off, Starting, Running, Ready, Stopping, Failed, Unknown)."
  value       = harvester_virtualmachine.this.state
}

output "network_interfaces" {
  description = "VM network interfaces, including resolved ip_address and interface_name once reported by the guest."
  value       = harvester_virtualmachine.this.network_interface
}

output "primary_ip_address" {
  description = "IP address of the first network interface. Empty string until the guest reports a lease."
  value       = try(harvester_virtualmachine.this.network_interface[0].ip_address, "")
}

output "cloudinit_secret_name" {
  description = "Cloud-init Secret name, or null when cloudinit.enabled is false."
  value       = try(harvester_cloudinit_secret.this[0].name, null)
}
