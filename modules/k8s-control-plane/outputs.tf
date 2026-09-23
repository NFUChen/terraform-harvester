output "control_plane_ip" {
  description = "Configured static IP address of the Kubernetes control-plane VM."
  value       = local.control_plane_ip
}

output "management_api_endpoint" {
  description = "Kubernetes API endpoint for management clients, served by the Harvester LoadBalancer."
  value       = "https://${harvester_loadbalancer.control_plane.ip_address}:${var.load_balancer.listener_port}"
}

output "load_balancer_ip" {
  description = "IP address allocated to the control-plane LoadBalancer from the Harvester IP pool."
  value       = harvester_loadbalancer.control_plane.ip_address
}

output "cluster_generation" {
  description = "Opaque digest of the control-plane bootstrap configuration. Pass this to workers so a rebuilt control plane forces them to rejoin the new cluster CA."
  value       = sha256(local.user_data)
}

output "join_token" {
  description = "Sensitive kubeadm bootstrap token for joining worker nodes."
  value       = local.join_token
  sensitive   = true
}

output "worker_join_command" {
  description = "Worker join command. CA verification is skipped because the CA hash is created inside the VM during kubeadm init."
  value       = "kubeadm join ${local.control_plane_ip}:6443 --token ${local.join_token} --discovery-token-unsafe-skip-ca-verification"
  sensitive   = true
}
