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
    condition     = strcontains(local.user_data, "--apiserver-cert-extra-sans=172.16.100.10")
    error_message = "The API server certificate must cover the configured static IP."
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
