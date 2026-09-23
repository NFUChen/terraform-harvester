output "namespace" {
  description = "Namespace shared by the target NAD and DHCP workload."
  value       = local.namespace
}

output "network_name" {
  description = "Target NetworkAttachmentDefinition name."
  value       = local.network_name
}

output "server_ip" {
  description = "Static IP bound by the dnsmasq pod on the VLAN interface."
  value       = local.server_ip
}

output "gateway" {
  description = "Gateway advertised to DHCP clients. The module does not create or verify this gateway."
  value       = local.gateway
}

output "pool_start" {
  description = "First address in the DHCP lease pool."
  value       = local.pool_start
}

output "pool_end" {
  description = "Last address in the DHCP lease pool."
  value       = local.pool_end
}

output "dns_servers" {
  description = "DNS servers advertised to DHCP clients."
  value       = local.dns_servers
}

output "deployment_name" {
  description = "Kubernetes Deployment running dnsmasq."
  value       = kubernetes_deployment_v1.dhcp.metadata[0].name
}

output "dnsmasq_config" {
  description = "Rendered dnsmasq configuration for review and troubleshooting."
  value       = local.dnsmasq_config
}
