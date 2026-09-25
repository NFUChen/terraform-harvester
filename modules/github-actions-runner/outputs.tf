output "name" {
  description = "Runner VM and GitHub Actions runner name."
  value       = module.runner.name
}

output "id" {
  description = "Harvester VM resource ID."
  value       = module.runner.id
}

output "primary_ip_address" {
  description = "Runner VM primary IP address once reported by the guest."
  value       = module.runner.primary_ip_address
}

output "state" {
  description = "Terraform-derived runner VM state."
  value       = module.runner.state
}
