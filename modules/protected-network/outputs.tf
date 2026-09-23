output "ids" {
  description = "Network IDs (namespace/name) keyed by NAD name. Pass these values to virtual-machine network_interface.network_name."
  value       = { for key, network in harvester_network.this : key => network.id }
}

output "names" {
  description = "NAD names keyed by the same stable keys supplied in var.networks."
  value       = { for key, network in harvester_network.this : key => network.name }
}

output "declared_vlan_ids" {
  description = "VLAN IDs currently declared in var.networks. Terraform freezes topology, so this can differ from observed_vlan_ids after an unsafe config edit. A difference means migration is required; ordinary apply will not update the NAD."
  value       = { for key, network in var.networks : key => network.vlan_id }
}

output "observed_vlan_ids" {
  description = "VLAN IDs last observed from live NAD/provider state. These are the effective values to use for operational inventory."
  value       = { for key, network in harvester_network.this : key => network.vlan_id }
}

output "declared_cluster_network_name" {
  description = "ClusterNetwork currently declared by this module call. Terraform freezes topology, so this can differ from observed_cluster_network_names after an unsafe config edit."
  value       = var.cluster_network_name
}

output "observed_cluster_network_names" {
  description = "ClusterNetwork names last observed on each live NAD, keyed by NAD name."
  value       = { for key, network in harvester_network.this : key => network.cluster_network_name }
}

output "declared_routes" {
  description = "Route configuration currently declared in var.networks. The NAD is create-once (ignore_changes=all), so compare this with observed_routes; differences require migration to a new network name."
  value = {
    for key, network in var.networks : key => {
      mode           = network.route.mode
      cidr           = network.route.cidr
      gateway        = network.route.gateway
      dhcp_server_ip = network.route.dhcp_server_ip
    }
  }
}

output "observed_routes" {
  description = "Route configuration last observed from the live NAD/provider state."
  value = {
    for key, network in harvester_network.this : key => {
      mode           = network.route_mode
      cidr           = network.route_cidr
      gateway        = network.route_gateway
      dhcp_server_ip = network.route_dhcp_server_ip
    }
  }
}

output "route_connectivity" {
  description = "Provider-observed route connectivity keyed by NAD name. This does not prove VM guest or application connectivity."
  value       = { for key, network in harvester_network.this : key => network.route_connectivity }
}

output "dhcp_server_ips" {
  description = "DHCP server IPs keyed by network name for networks with enable_dhcp=true."
  value       = { for key, service in module.dhcp : key => service.server_ip }
}

output "gateway_ips" {
  description = "NAT gateway IPs keyed by network name for networks with enable_nat=true."
  value       = { for key, service in module.nat : key => service.gateway_ip }
}
