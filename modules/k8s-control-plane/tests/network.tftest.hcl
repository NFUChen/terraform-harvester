mock_provider "harvester" {}

variables {
  root_image = "harvester-public/ubuntu"

  network = {
    name    = "harvester-public/v100"
    address = "172.16.100.10/24"
    gateway = "172.16.100.1"
  }
}

run "static_address_reaches_every_consumer" {
  command = apply

  assert {
    condition     = local.control_plane_ip == "172.16.100.10"
    error_message = "The control-plane IP must be the host portion of network.address."
  }

  assert {
    condition     = output.control_plane_ip == "172.16.100.10"
    error_message = "The advertised control-plane IP must come from configuration, not from a runtime guest lease."
  }

  assert {
    condition     = strcontains(output.worker_join_command, "kubeadm join 172.16.100.10:6443")
    error_message = "The worker join command must target the configured static control-plane IP."
  }

  assert {
    condition     = strcontains(local.user_data, "--apiserver-advertise-address=172.16.100.10")
    error_message = "kubeadm must advertise the configured static IP so worker joins reach the API server."
  }

  assert {
    condition     = strcontains(local.user_data, "--apiserver-cert-extra-sans=172.16.100.10,192.168.18.240,192.168.18.241,192.168.18.242,192.168.18.243,192.168.18.244,192.168.18.245")
    error_message = "The API server certificate must cover the cluster VLAN IP and every possible LoadBalancer pool address."
  }

  assert {
    condition     = length(module.control_plane.network_interfaces["k8s-control-plane-01"]) == 2
    error_message = "The control plane must have management and cluster interfaces."
  }

  assert {
    condition     = harvester_ippool.control_plane.range[0].start == "192.168.18.240" && harvester_ippool.control_plane.range[0].end == "192.168.18.245"
    error_message = "The default IP pool must use the agreed home-network reservation."
  }

  assert {
    condition     = harvester_loadbalancer.control_plane.ipam == "pool" && harvester_loadbalancer.control_plane.ippool == harvester_ippool.control_plane.name
    error_message = "The control-plane LoadBalancer must allocate from its managed IP pool, never DHCP."
  }

  assert {
    condition     = one(harvester_loadbalancer.control_plane.backend_selector).key == "harvesterhci.io/vmName"
    error_message = "The LoadBalancer must select the exact control-plane VM by its stable Harvester VM name label."
  }

  assert {
    condition     = harvester_loadbalancer.control_plane.listener[0].port == 6443 && harvester_loadbalancer.control_plane.listener[0].backend_port == 6443
    error_message = "The management listener must forward TCP 6443 to kube-apiserver port 6443."
  }

  assert {
    condition     = strcontains(local.network_data, "172.16.100.10/24")
    error_message = "Cloud-init network data must assign the configured static address to the guest."
  }

  assert {
    condition     = strcontains(local.network_data, "172.16.100.1")
    error_message = "Cloud-init network data must configure the configured default gateway."
  }
}

run "gateway_outside_subnet_rejected" {
  command = plan

  variables {
    network = {
      name    = "harvester-public/v100"
      address = "172.16.100.10/24"
      gateway = "172.16.200.1"
    }
  }

  expect_failures = [var.network]
}

run "address_without_prefix_rejected" {
  command = plan

  variables {
    network = {
      name    = "harvester-public/v100"
      address = "172.16.100.10"
      gateway = "172.16.100.1"
    }
  }

  expect_failures = [var.network]
}
