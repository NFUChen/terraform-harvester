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

output "load_balancer_ip" {
  description = "Management-facing HTTP LoadBalancer IP."
  value       = harvester_loadbalancer.workers.ip_address
}

output "http_endpoint" {
  description = "HTTP endpoint balanced across all worker VM backends."
  value       = "http://${harvester_loadbalancer.workers.ip_address}:${var.load_balancer.listener_port}"
}
