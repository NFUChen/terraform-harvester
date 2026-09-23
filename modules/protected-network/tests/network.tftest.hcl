mock_provider "kubernetes" {}

mock_provider "harvester" {
  mock_data "harvester_clusternetwork" {
    defaults = {
      name  = "workload"
      state = "ready"
    }
  }
}

run "minimal_auto_network" {
  command = plan

  variables {
    namespace            = "harvester-public"
    cluster_network_name = "workload"

    networks = {
      "production-v100" = {
        vlan_id = 100
      }
    }
  }

  assert {
    condition     = harvester_network.this["production-v100"].name == "production-v100"
    error_message = "The networks map key must be the exact NAD name."
  }

  assert {
    condition     = harvester_network.this["production-v100"].vlan_id == 100
    error_message = "The declared VLAN ID must be applied on creation."
  }

  assert {
    condition     = harvester_network.this["production-v100"].route_mode == "auto"
    error_message = "Route mode must default to auto."
  }

  assert {
    condition     = harvester_network.this["production-v100"].cluster_network_name == "workload"
    error_message = "The cluster network must be applied."
  }

  assert {
    condition     = output.declared_vlan_ids["production-v100"] == 100 && output.observed_vlan_ids["production-v100"] == 100
    error_message = "Declared and observed VLAN outputs must agree on initial creation."
  }
}

run "manual_route_network" {
  command = plan

  variables {
    namespace            = "harvester-public"
    cluster_network_name = "workload"

    networks = {
      "production-v200" = {
        vlan_id = 200
        route = {
          mode    = "manual"
          cidr    = "172.16.200.0/24"
          gateway = "172.16.200.1"
        }
      }
    }
  }

  assert {
    condition     = harvester_network.this["production-v200"].route_mode == "manual"
    error_message = "Manual route mode must be applied."
  }

  assert {
    condition     = harvester_network.this["production-v200"].route_cidr == "172.16.200.0/24"
    error_message = "Manual route CIDR must be applied."
  }

  assert {
    condition     = harvester_network.this["production-v200"].route_gateway == "172.16.200.1"
    error_message = "Manual route gateway must be applied."
  }

  assert {
    condition     = output.names["production-v200"] == "production-v200"
    error_message = "names output must expose the NAD name."
  }

  assert {
    condition     = output.declared_cluster_network_name == "workload"
    error_message = "declared_cluster_network_name must expose the module-wide ClusterNetwork."
  }

  assert {
    condition     = output.observed_cluster_network_names["production-v200"] == "workload"
    error_message = "observed_cluster_network_names must reflect the live NAD ClusterNetwork on creation."
  }

  assert {
    condition = (
      output.declared_routes["production-v200"].mode == "manual" &&
      output.declared_routes["production-v200"].cidr == "172.16.200.0/24" &&
      output.declared_routes["production-v200"].gateway == "172.16.200.1" &&
      output.declared_routes["production-v200"].dhcp_server_ip == null
    )
    error_message = "declared_routes must expose the full declared route shape."
  }

  assert {
    condition     = output.observed_routes["production-v200"].cidr == "172.16.200.0/24" && output.observed_routes["production-v200"].gateway == "172.16.200.1"
    error_message = "observed_routes must agree with declared_routes on initial creation."
  }
}

run "two_networks_independent_topology" {
  command = plan

  variables {
    namespace            = "harvester-public"
    cluster_network_name = "workload"

    networks = {
      "production-v100" = { vlan_id = 100 }
      "production-v101" = { vlan_id = 101 }
    }
  }

  assert {
    condition     = harvester_network.this["production-v100"].vlan_id == 100 && harvester_network.this["production-v101"].vlan_id == 101
    error_message = "Each network in the map must keep its own independent VLAN."
  }
}

run "auto_mode_with_gateway_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"

    networks = {
      "production-v100" = {
        vlan_id = 100
        route = {
          mode    = "auto"
          gateway = "172.16.100.1"
        }
      }
    }
  }

  expect_failures = [
    var.networks,
  ]
}

run "manual_mode_missing_cidr_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"

    networks = {
      "production-v100" = {
        vlan_id = 100
        route = {
          mode    = "manual"
          gateway = "172.16.100.1"
        }
      }
    }
  }

  expect_failures = [
    var.networks,
  ]
}

run "malformed_cidr_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"

    networks = {
      "production-v100" = {
        vlan_id = 100
        route = {
          mode    = "manual"
          cidr    = "not-a-cidr"
          gateway = "172.16.100.1"
        }
      }
    }
  }

  expect_failures = [
    var.networks,
  ]
}

run "malformed_gateway_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"

    networks = {
      "production-v100" = {
        vlan_id = 100
        route = {
          mode    = "manual"
          cidr    = "172.16.100.0/24"
          gateway = "not-an-ip"
        }
      }
    }
  }

  expect_failures = [
    var.networks,
  ]
}

run "invalid_route_mode_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"

    networks = {
      "production-v100" = {
        vlan_id = 100
        route = {
          mode = "static"
        }
      }
    }
  }

  expect_failures = [
    var.networks,
  ]
}

run "invalid_namespace_rejected" {
  command = plan

  variables {
    namespace            = "Not_Valid"
    cluster_network_name = "workload"

    networks = {
      "production-v100" = { vlan_id = 100 }
    }
  }

  expect_failures = [
    var.namespace,
  ]
}

run "invalid_cluster_network_name_rejected" {
  command = plan

  variables {
    cluster_network_name = "Not_Valid"

    networks = {
      "production-v100" = { vlan_id = 100 }
    }
  }

  expect_failures = [
    var.cluster_network_name,
  ]
}

run "global_label_cannot_override_clusternetwork_label" {
  command = plan

  variables {
    cluster_network_name = "workload"
    labels = {
      "network.harvesterhci.io/clusternetwork" = "attacker-controlled"
    }

    networks = {
      "production-v100" = { vlan_id = 100 }
    }
  }

  expect_failures = [
    var.labels,
  ]
}

run "invalid_network_name_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"

    networks = {
      "Production_V100" = {
        vlan_id = 100
      }
    }
  }

  expect_failures = [
    var.networks,
  ]
}

run "vlan_id_out_of_range_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"

    networks = {
      "production-v9999" = {
        vlan_id = 9999
      }
    }
  }

  expect_failures = [
    var.networks,
  ]
}

run "auto_mode_with_cidr_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"

    networks = {
      "production-v100" = {
        vlan_id = 100
        route = {
          mode = "auto"
          cidr = "172.16.100.0/24"
        }
      }
    }
  }

  expect_failures = [
    var.networks,
  ]
}

run "manual_mode_missing_gateway_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"

    networks = {
      "production-v100" = {
        vlan_id = 100
        route = {
          mode = "manual"
          cidr = "172.16.100.0/24"
        }
      }
    }
  }

  expect_failures = [
    var.networks,
  ]
}

run "gateway_outside_cidr_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"

    networks = {
      "production-v100" = {
        vlan_id = 100
        route = {
          mode    = "manual"
          cidr    = "172.16.100.0/24"
          gateway = "10.0.0.1"
        }
      }
    }
  }

  expect_failures = [
    var.networks,
  ]
}

run "dhcp_with_manual_route_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"

    networks = {
      "production-v100" = {
        vlan_id = 100
        route = {
          mode           = "manual"
          cidr           = "172.16.100.0/24"
          gateway        = "172.16.100.1"
          dhcp_server_ip = "172.16.100.10"
        }
      }
    }
  }

  expect_failures = [
    var.networks,
  ]
}

run "invalid_dhcp_server_ip_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"

    networks = {
      "production-v100" = {
        vlan_id = 100
        route = {
          mode           = "auto"
          dhcp_server_ip = "not-an-ip"
        }
      }
    }
  }

  expect_failures = [
    var.networks,
  ]
}

run "caller_cannot_override_clusternetwork_label" {
  command = plan

  variables {
    cluster_network_name = "workload"

    networks = {
      "production-v100" = {
        vlan_id = 100
        labels = {
          "network.harvesterhci.io/clusternetwork" = "attacker-controlled"
        }
      }
    }
  }

  expect_failures = [
    var.networks,
  ]
}

run "network_with_dhcp_and_nat_services" {
  command = plan

  variables {
    namespace            = "harvester-public"
    cluster_network_name = "workload"

    networks = {
      "v100" = {
        vlan_id = 100
        services = {
          cidr              = "172.16.100.0/24"
          enable_dhcp       = true
          enable_nat        = true
          pool_start_offset = 100
          pool_end_offset   = 200
          dns_servers       = ["1.1.1.1", "8.8.8.8"]
          node_selector = {
            "kubernetes.io/hostname" = "test-node"
          }
        }
      }
    }
  }

  assert {
    condition     = module.dhcp["v100"].server_ip == "172.16.100.2"
    error_message = "DHCP must reserve host offset 2 automatically."
  }

  assert {
    condition     = module.nat["v100"].gateway_ip == "172.16.100.1"
    error_message = "NAT must reserve host offset 1 automatically."
  }
}

run "services_disabled_create_no_workloads" {
  command = plan

  variables {
    cluster_network_name = "workload"
    networks = {
      "isolated-v200" = {
        vlan_id = 200
      }
    }
  }

  assert {
    condition     = length(module.dhcp) == 0 && length(module.nat) == 0
    error_message = "Networks without services must remain pure NADs for backward compatibility."
  }
}

run "all_services_disabled_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"
    networks = {
      "v100" = {
        vlan_id = 100
        services = {
          cidr        = "172.16.100.0/24"
          enable_dhcp = false
          enable_nat  = false
          node_selector = {
            "kubernetes.io/hostname" = "test-node"
          }
        }
      }
    }
  }

  expect_failures = [var.networks]
}

run "service_network_name_must_fit_child_resources" {
  command = plan

  variables {
    cluster_network_name = "workload"
    networks = {
      "vlan.with.dots" = {
        vlan_id = 100
        services = {
          cidr = "172.16.100.0/24"
          node_selector = {
            "kubernetes.io/hostname" = "test-node"
          }
        }
      }
    }
  }

  expect_failures = [var.networks]
}

run "empty_networks_map_rejected" {
  command = plan

  variables {
    cluster_network_name = "workload"
    networks             = {}
  }

  expect_failures = [
    var.networks,
  ]
}
