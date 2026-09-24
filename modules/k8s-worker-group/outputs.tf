output "instance_names" {
  description = "Stable worker VM names."
  value       = sort(keys(var.instances))
}

output "worker_ips" {
  description = "Configured VLAN IP addresses keyed by worker name."
  value = {
    for name, instance in var.instances :
    name => split("/", instance.address)[0]
  }
}

output "ubuntu_password" {
  description = "Generated plaintext ubuntu password shared by the worker group. Stored in Terraform state; handle as a secret."
  value       = random_password.ubuntu.result
  sensitive   = true
}

