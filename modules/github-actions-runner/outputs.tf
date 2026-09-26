output "names" {
  description = "GitHub Actions runner VM and agent names, one per registration token."
  value       = local.runner_names
}

output "ids" {
  description = "Harvester VM resource IDs keyed by runner name."
  value       = { for name, runner in module.runner : name => runner.id }
}

output "primary_ip_addresses" {
  description = "Runner VM primary IP addresses keyed by runner name, once reported by the guest."
  value       = { for name, runner in module.runner : name => runner.primary_ip_address }
}

output "states" {
  description = "Terraform-derived runner VM states keyed by runner name."
  value       = { for name, runner in module.runner : name => runner.state }
}
