output "control_plane_ip" {
  description = "Configured static IP address of the Kubernetes control-plane VM."
  value       = local.control_plane_ip
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
