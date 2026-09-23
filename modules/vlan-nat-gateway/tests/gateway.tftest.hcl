mock_provider "kubernetes" {}
variables {
  node_selector = { "kubernetes.io/hostname" = "test-node" }
}
run "valid_gateway" {
  command = plan
  variables {
    network_id = "harvester-public/v100"
    cidr       = "172.16.100.0/24"
  }
  assert {
    condition     = local.gateway_ip == "172.16.100.1"
    error_message = "gateway must default to host offset 1"
  }
  assert {
    condition     = kubernetes_deployment_v1.gateway.spec[0].strategy[0].type == "Recreate"
    error_message = "gateway must use Recreate"
  }
  assert {
    condition = strcontains(
      join(" ", kubernetes_deployment_v1.gateway.spec[0].template[0].spec[0].container[0].args),
      "iptables -t nat",
    )
    error_message = "startup must configure NAT"
  }
  assert {
    condition = strcontains(
      join(" ", kubernetes_deployment_v1.gateway.spec[0].template[0].spec[0].container[0].args),
      "TCPMSS --clamp-mss-to-pmtu",
    )
    error_message = "startup must clamp TCP MSS to the path MTU; without this, TLS handshakes over the VLAN silently hang whenever the egress MTU is smaller than 1500 (e.g. Harvester pod-network at 1450)."
  }
  assert {
    condition     = kubernetes_deployment_v1.gateway.spec[0].template[0].spec[0].init_container[0].security_context[0].privileged == true
    error_message = "a privileged one-shot init container must enable ip_forward in the Pod network namespace"
  }
}
run "invalid_network_id" {
  command = plan
  variables {
    network_id = "v100"
    cidr       = "172.16.100.0/24"
  }
  expect_failures = [var.network_id]
}
run "invalid_cidr" {
  command = plan
  variables {
    network_id = "harvester-public/v100"
    cidr       = "bad"
  }
  expect_failures = [var.cidr]
}
run "node_selector_required" {
  command = plan
  variables {
    network_id    = "harvester-public/v100"
    cidr          = "172.16.100.0/24"
    node_selector = {}
  }
  expect_failures = [var.node_selector]
}
