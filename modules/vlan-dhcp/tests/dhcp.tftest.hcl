mock_provider "kubernetes" {}

variables {
  node_selector = {
    "kubernetes.io/hostname" = "test-node"
  }
}

run "minimal_valid_call" {
  command = plan

  variables {
    network_id        = "harvester-public/database-v110"
    cidr              = "172.16.110.0/24"
    pool_start_offset = 100
    pool_end_offset   = 200
  }

  assert {
    condition     = local.namespace == "harvester-public"
    error_message = "namespace must be parsed from network_id."
  }

  assert {
    condition     = local.network_name == "database-v110"
    error_message = "network name must be parsed from network_id."
  }

  assert {
    condition     = local.gateway == "172.16.110.1"
    error_message = "gateway must default to host offset 1."
  }

  assert {
    condition     = local.server_ip == "172.16.110.2"
    error_message = "server_ip must default to host offset 2."
  }

  assert {
    condition     = local.dns_server == "172.16.110.1"
    error_message = "dns_server must default to the gateway."
  }

  assert {
    condition     = local.pool_start == "172.16.110.100"
    error_message = "pool_start must be computed from pool_start_offset."
  }

  assert {
    condition     = local.pool_end == "172.16.110.200"
    error_message = "pool_end must be computed from pool_end_offset."
  }

  assert {
    condition     = kubernetes_deployment_v1.dhcp.metadata[0].namespace == "harvester-public"
    error_message = "the DHCP Deployment must run in the same namespace as the NAD to avoid Multus namespace isolation."
  }

  assert {
    condition     = kubernetes_deployment_v1.dhcp.spec[0].strategy[0].type == "Recreate"
    error_message = "the Deployment must use Recreate so two dnsmasq replicas never race for the same static IP/DHCP range."
  }

  assert {
    condition     = kubernetes_deployment_v1.dhcp.spec[0].replicas == "1"
    error_message = "exactly one DHCP server per VLAN must run at a time."
  }

  assert {
    condition = jsondecode(
      kubernetes_deployment_v1.dhcp.spec[0].template[0].metadata[0].annotations["k8s.v1.cni.cncf.io/networks"]
      ) == [{
        name      = "database-v110"
        namespace = "harvester-public"
        interface = "net1"
    }]
    error_message = "the Multus annotation must request the exact namespaced NAD as interface net1."
  }

  assert {
    condition     = strcontains(local.dnsmasq_config, "dhcp-range=172.16.110.100,172.16.110.200,255.255.255.0,12h")
    error_message = "dnsmasq config must contain the computed range and netmask."
  }

  assert {
    condition     = strcontains(local.dnsmasq_config, "dhcp-option=option:router,172.16.110.1") && strcontains(local.dnsmasq_config, "dhcp-option=option:dns-server,172.16.110.1")
    error_message = "dnsmasq config must advertise the derived gateway and default DNS server."
  }

  assert {
    condition = alltrue([
      for directive in [
        "port=0",
        "interface=net1",
        "bind-interfaces",
        "dhcp-authoritative",
        "dhcp-leasefile=/tmp/dnsmasq.leases",
        "pid-file=",
        "log-dhcp",
        "log-facility=-",
      ] : strcontains(local.dnsmasq_config, directive)
    ])
    error_message = "dnsmasq config must disable DNS service, bind only net1, remain authoritative, keep leases on writable /tmp, disable the unnecessary PID file, and emit DHCP logs."
  }

  assert {
    condition     = kubernetes_deployment_v1.dhcp.spec[0].template[0].spec[0].automount_service_account_token == false
    error_message = "the DHCP pod must not receive a Kubernetes ServiceAccount token."
  }

  assert {
    condition     = kubernetes_deployment_v1.dhcp.spec[0].template[0].spec[0].container[0].security_context[0].read_only_root_filesystem == true
    error_message = "the DHCP container root filesystem must be read-only."
  }

  assert {
    condition     = toset(kubernetes_deployment_v1.dhcp.spec[0].template[0].spec[0].container[0].security_context[0].capabilities[0].add) == toset(["NET_ADMIN", "NET_RAW", "NET_BIND_SERVICE", "SETUID", "SETGID"])
    error_message = "the DHCP container must receive only the required network capabilities plus SETUID/SETGID so dnsmasq can drop privileges to nobody after binding sockets."
  }

  assert {
    condition = strcontains(
      join(" ", kubernetes_deployment_v1.dhcp.spec[0].template[0].spec[0].container[0].readiness_probe[0].exec[0].command),
      "172.16.110.2/24",
      ) && strcontains(
      join(" ", kubernetes_deployment_v1.dhcp.spec[0].template[0].spec[0].container[0].readiness_probe[0].exec[0].command),
      "67",
    )
    error_message = "readiness must verify the expected net1 address and UDP 67 listener."
  }
}

run "custom_offsets_and_dns" {
  command = plan

  variables {
    network_id        = "harvester-public/database-v110"
    cidr              = "172.16.110.0/28"
    pool_start_offset = 8
    pool_end_offset   = 14
    gateway_offset    = 1
    server_offset     = 2
    dns_servers       = ["1.1.1.1", "8.8.8.8"]
    domain            = "lab.internal"
  }

  assert {
    condition     = strcontains(local.dnsmasq_config, "dhcp-option=option:domain-name,lab.internal")
    error_message = "a validated domain must render as exactly one dnsmasq domain-name option."
  }

  assert {
    condition     = local.gateway == "172.16.110.1"
    error_message = "gateway must respect a /28 subnet."
  }

  assert {
    condition     = local.pool_start == "172.16.110.8"
    error_message = "pool_start must respect a /28 subnet."
  }

  assert {
    condition     = local.pool_end == "172.16.110.14"
    error_message = "pool_end must respect a /28 subnet."
  }
}

run "invalid_network_id_rejected" {
  command = plan

  variables {
    network_id        = "no-slash-here"
    cidr              = "172.16.110.0/24"
    pool_start_offset = 100
    pool_end_offset   = 200
  }

  expect_failures = [
    var.network_id,
  ]
}

run "invalid_cidr_rejected" {
  command = plan

  variables {
    network_id        = "harvester-public/database-v110"
    cidr              = "not-a-cidr"
    pool_start_offset = 100
    pool_end_offset   = 200
  }

  expect_failures = [
    var.cidr,
  ]
}

run "cidr_too_small_for_offsets_rejected" {
  command = plan

  variables {
    network_id        = "harvester-public/database-v110"
    cidr              = "172.16.110.0/31"
    pool_start_offset = 100
    pool_end_offset   = 200
  }

  expect_failures = [
    var.cidr,
  ]
}

run "pool_start_after_end_rejected" {
  command = plan

  variables {
    network_id        = "harvester-public/database-v110"
    cidr              = "172.16.110.0/24"
    pool_start_offset = 200
    pool_end_offset   = 100
  }

  expect_failures = [
    var.pool_end_offset,
  ]
}

run "gateway_offset_inside_pool_rejected" {
  command = plan

  variables {
    network_id        = "harvester-public/database-v110"
    cidr              = "172.16.110.0/24"
    pool_start_offset = 1
    pool_end_offset   = 200
  }

  expect_failures = [
    var.pool_start_offset,
  ]
}

run "server_offset_inside_pool_rejected" {
  command = plan

  variables {
    network_id        = "harvester-public/database-v110"
    cidr              = "172.16.110.0/24"
    pool_start_offset = 2
    pool_end_offset   = 200
  }

  expect_failures = [
    var.pool_start_offset,
  ]
}

run "empty_dns_servers_rejected" {
  command = plan

  variables {
    network_id        = "harvester-public/database-v110"
    cidr              = "172.16.110.0/24"
    pool_start_offset = 100
    pool_end_offset   = 200
    dns_servers       = []
  }

  expect_failures = [
    var.dns_servers,
  ]
}

run "invalid_dns_server_rejected" {
  command = plan

  variables {
    network_id        = "harvester-public/database-v110"
    cidr              = "172.16.110.0/24"
    pool_start_offset = 100
    pool_end_offset   = 200
    dns_servers       = ["not-an-ip"]
  }

  expect_failures = [
    var.dns_servers,
  ]
}

run "node_selector_required" {
  command = plan

  variables {
    network_id        = "harvester-public/database-v110"
    cidr              = "172.16.110.0/24"
    pool_start_offset = 100
    pool_end_offset   = 200
    node_selector     = {}
  }

  expect_failures = [
    var.node_selector,
  ]
}

run "domain_configuration_injection_rejected" {
  command = plan

  variables {
    network_id        = "harvester-public/database-v110"
    cidr              = "172.16.110.0/24"
    pool_start_offset = 100
    pool_end_offset   = 200
    domain            = "example.internal\ndhcp-range=10.0.0.1,10.0.0.10"
  }

  expect_failures = [
    var.domain,
  ]
}

run "zero_lease_time_rejected" {
  command = plan

  variables {
    network_id        = "harvester-public/database-v110"
    cidr              = "172.16.110.0/24"
    pool_start_offset = 100
    pool_end_offset   = 200
    lease_time        = "0s"
  }

  expect_failures = [
    var.lease_time,
  ]
}

run "lease_time_format_validated" {
  command = plan

  variables {
    network_id        = "harvester-public/database-v110"
    cidr              = "172.16.110.0/24"
    pool_start_offset = 100
    pool_end_offset   = 200
    lease_time        = "not-a-duration"
  }

  expect_failures = [
    var.lease_time,
  ]
}
