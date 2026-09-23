mock_provider "harvester" {}

variables {
  root_image = "harvester-public/ubuntu"

  network = {
    name    = "harvester-public/v100"
    address = "172.16.100.10/24"
    gateway = "172.16.100.1"
  }

  load_balancer = {
    address = "192.168.18.240"
    subnet  = "192.168.18.1/24"
    gateway = "192.168.18.1"
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
    condition     = strcontains(local.user_data, "advertiseAddress: \"172.16.100.10\"")
    error_message = "kubeadm must advertise the configured static IP so worker joins reach the API server."
  }

  assert {
    condition     = strcontains(local.user_data, "- name: \"node-ip\"") && strcontains(local.user_data, "value: \"172.16.100.10\"")
    error_message = "The control-plane kubelet must pin node-ip to the routable VLAN address, not the masquerade management address."
  }

  assert {
    condition     = strcontains(local.user_data, "- \"172.16.100.10\"") && strcontains(local.user_data, "- \"192.168.18.240\"")
    error_message = "The API server certificate must cover the cluster VLAN IP and the caller-supplied LoadBalancer address."
  }

  assert {
    condition     = strcontains(local.user_data, "kube-flannel.yml")
    error_message = "The control plane must install a CNI so nodes can leave NotReady."
  }

  assert {
    condition     = strcontains(local.user_data, "sha256sum -c -")
    error_message = "The downloaded Flannel manifest must be verified against a pinned checksum."
  }

  assert {
    condition     = length(module.control_plane.network_interfaces["k8s-control-plane-01"]) == 2
    error_message = "The control plane must have management and cluster interfaces."
  }

  assert {
    condition     = harvester_ippool.control_plane.range[0].start == "192.168.18.240" && harvester_ippool.control_plane.range[0].end == "192.168.18.240"
    error_message = "The IP pool must pin the exact caller-supplied address, not a range, so the management endpoint never changes."
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

run "load_balancer_gateway_outside_subnet_rejected" {
  command = plan

  variables {
    load_balancer = {
      address = "192.168.18.240"
      subnet  = "192.168.18.1/24"
      gateway = "10.0.0.1"
    }
  }

  expect_failures = [var.load_balancer]
}
