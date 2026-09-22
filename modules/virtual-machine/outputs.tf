output "instance_names" {
  description = "Names of all VMs created by this module call, in <name_prefix>-NN order."
  value       = local.instance_names
}

output "ids" {
  description = "Map of instance name to Terraform resource ID (namespace/name)."
  value       = { for name, vm in harvester_virtualmachine.this : name => vm.id }
}

output "node_names" {
  description = "Map of instance name to the Harvester node currently running the VM. Empty until the VM is scheduled."
  value       = { for name, vm in harvester_virtualmachine.this : name => vm.node_name }
}

output "states" {
  description = "Map of instance name to the Terraform-derived VM state (Off, Starting, Running, Ready, Stopping, Failed, Unknown)."
  value       = { for name, vm in harvester_virtualmachine.this : name => vm.state }
}

output "network_interfaces" {
  description = "Map of instance name to its network interfaces, including any resolved ip_address and interface_name once the guest reports them."
  value       = { for name, vm in harvester_virtualmachine.this : name => vm.network_interface }
}

output "primary_ip_addresses" {
  description = "Map of instance name to the IP address of its first network interface. Empty string until the guest reports a lease."
  value = {
    for name, vm in harvester_virtualmachine.this :
    name => try(vm.network_interface[0].ip_address, "")
  }
}

output "cloudinit_secret_names" {
  description = "Map of instance name to its cloud-init Secret name. Empty map when cloudinit.enabled = false."
  value       = { for name, secret in harvester_cloudinit_secret.this : name => secret.name }
}
