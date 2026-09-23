mock_provider "harvester" {}

run "cloudinit_replacement_fingerprint" {
  command = plan

  variables {
    name_prefix = "test"
    root_image  = null
    cloudinit = {
      enabled      = true
      type         = "noCloud"
      user_data    = "#cloud-config\nhostname: test\n"
      network_data = "version: 2\n"
    }
  }

  assert {
    condition = local.cloudinit_fingerprint == sha256(jsonencode({
      enabled      = true
      type         = "noCloud"
      user_data    = "#cloud-config\nhostname: test\n"
      network_data = "version: 2\n"
    }))
    error_message = "The replacement fingerprint must cover the complete effective cloud-init configuration."
  }

  assert {
    condition = local.cloudinit_fingerprint != sha256(jsonencode({
      enabled      = false
      type         = "noCloud"
      user_data    = "#cloud-config\nhostname: test\n"
      network_data = "version: 2\n"
    }))
    error_message = "Changing cloud-init enabled state must alter the replacement fingerprint."
  }

  assert {
    condition = local.cloudinit_fingerprint != sha256(jsonencode({
      enabled      = true
      type         = "configDrive"
      user_data    = "#cloud-config\nhostname: test\n"
      network_data = "version: 2\n"
    }))
    error_message = "Changing cloud-init type must alter the replacement fingerprint."
  }

  assert {
    condition = local.cloudinit_fingerprint != sha256(jsonencode({
      enabled      = true
      type         = "noCloud"
      user_data    = "#cloud-config\nhostname: changed\n"
      network_data = "version: 2\n"
    }))
    error_message = "Changing user data must alter the replacement fingerprint."
  }

  assert {
    condition = local.cloudinit_fingerprint != sha256(jsonencode({
      enabled      = true
      type         = "noCloud"
      user_data    = "#cloud-config\nhostname: test\n"
      network_data = "version: 1\n"
    }))
    error_message = "Changing network data must alter the replacement fingerprint."
  }
}
