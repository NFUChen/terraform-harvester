mock_provider "harvester" {}

variables {
  root_image          = "harvester-public/ubuntu"
  github_url          = "https://github.com/example/example-repository"
  registration_token  = "AABBCCDDEEFFGGHHIIJJKK"
  ssh_authorized_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyMaterial user@example"]
}

run "defaults_register_against_management_network" {
  command = plan

  assert {
    condition     = module.runner.network_interfaces[0].type == "masquerade"
    error_message = "Without an explicit network, the runner must use the masquerade management network."
  }

  assert {
    condition     = strcontains(local.user_data, "--url 'https://github.com/example/example-repository'")
    error_message = "Cloud-init must configure the runner against the supplied repository URL."
  }

  assert {
    condition     = strcontains(local.user_data, "--token 'AABBCCDDEEFFGGHHIIJJKK'")
    error_message = "Cloud-init must pass the supplied registration token to config.sh."
  }

  assert {
    condition     = strcontains(local.user_data, "sha256sum -c -")
    error_message = "The downloaded runner tarball must be verified against a pinned checksum."
  }

  assert {
    condition     = strcontains(local.user_data, "actions-runner-linux-x64-2.337.0.tar.gz")
    error_message = "The runner download URL must use the pinned runner_version."
  }

  assert {
    condition     = !strcontains(local.user_data, "--labels")
    error_message = "No --labels flag should be emitted when labels is empty."
  }

  assert {
    condition     = !strcontains(local.user_data, "--runnergroup")
    error_message = "No --runnergroup flag should be emitted when runner_group is null."
  }
}

run "vlan_network_uses_bridge_type" {
  command = plan

  variables {
    network = {
      name = "default/v100"
    }
  }

  assert {
    condition     = module.runner.network_interfaces[0].type == "bridge"
    error_message = "Naming a VLAN network must select bridge networking, not masquerade."
  }
}

run "labels_and_runner_group_are_rendered" {
  command = plan

  variables {
    labels       = ["linux", "x64", "harvester"]
    runner_group = "infra"
  }

  assert {
    condition     = strcontains(local.user_data, "--labels 'harvester,linux,x64'")
    error_message = "Labels must be rendered as a deterministic, sorted, comma-separated list."
  }

  assert {
    condition     = strcontains(local.user_data, "--runnergroup 'infra'")
    error_message = "A configured runner_group must be passed to config.sh."
  }
}

run "invalid_github_url_rejected" {
  command = plan

  variables {
    github_url = "https://gitlab.com/example/example-repository"
  }

  expect_failures = [var.github_url]
}

run "empty_registration_token_rejected" {
  command = plan

  variables {
    registration_token = "   "
  }

  expect_failures = [var.registration_token]
}

run "label_with_comma_rejected" {
  command = plan

  variables {
    labels = ["bad,label"]
  }

  expect_failures = [var.labels]
}
