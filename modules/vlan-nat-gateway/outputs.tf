output "gateway_ip" { value = local.gateway_ip }
output "deployment_name" { value = kubernetes_deployment_v1.gateway.metadata[0].name }
output "namespace" { value = local.namespace }
output "network_name" { value = local.network_name }
