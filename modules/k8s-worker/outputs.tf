output "worker_ip" {
  description = "Configured static IP address of the Kubernetes worker VM."
  value       = split("/", var.network.address)[0]
}

output "instance_name" {
  description = "Name of the worker VM."
  value       = module.worker.instance_names[0]
}
