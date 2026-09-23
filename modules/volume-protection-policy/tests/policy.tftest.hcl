mock_provider "kubernetes" {}

run "policy_denies_and_fails_closed" {
  command = plan

  variables {
    break_glass_usernames = ["platform-break-glass"]
  }

  assert {
    condition     = kubernetes_manifest.policy.manifest.spec.failurePolicy == "Fail"
    error_message = "PVC protection must fail closed."
  }

  assert {
    condition     = kubernetes_manifest.binding.manifest.spec.validationActions == ["Deny"]
    error_message = "The binding must enforce Deny, not only Audit or Warn."
  }

  assert {
    condition     = kubernetes_manifest.policy.manifest.spec.validations[0].expression == "request.userInfo.username in [\"platform-break-glass\"] || !has(oldObject.metadata.labels) || !(\"platform.harvester.io/protected\" in oldObject.metadata.labels) || oldObject.metadata.labels[\"platform.harvester.io/protected\"] != 'true' || (request.operation == 'UPDATE' && has(object.metadata.labels) && \"platform.harvester.io/protected\" in object.metadata.labels && object.metadata.labels[\"platform.harvester.io/protected\"] == 'true')"
    error_message = "The generated CEL expression changed; re-verify the full admission matrix against a real API server before accepting it."
  }

  assert {
    condition     = kubernetes_manifest.policy.manifest.spec.matchConstraints.resourceRules[0].resources == ["persistentvolumeclaims"]
    error_message = "The policy must constrain PVC resources."
  }

  assert {
    condition     = toset(kubernetes_manifest.policy.manifest.spec.matchConstraints.resourceRules[0].operations) == toset(["UPDATE", "DELETE"])
    error_message = "The policy must intercept both DELETE and protection-label-removing UPDATE."
  }

  assert {
    condition     = kubernetes_manifest.policy.manifest.spec.validations[0].reason == "Forbidden"
    error_message = "Denied requests must surface as Forbidden."
  }
}

run "multiple_break_glass_identities_are_sorted_and_exact" {
  command = plan

  variables {
    break_glass_usernames = ["zeta-break-glass", "alpha-break-glass"]
  }

  assert {
    condition     = strcontains(kubernetes_manifest.policy.manifest.spec.validations[0].expression, "request.userInfo.username in [\"alpha-break-glass\", \"zeta-break-glass\"]")
    error_message = "Break-glass identities must be exact, quoted, and deterministically ordered to avoid spurious policy diffs."
  }
}

run "break_glass_username_with_whitespace_rejected" {
  command = plan

  variables {
    break_glass_usernames = [" platform-break-glass"]
  }

  expect_failures = [
    var.break_glass_usernames,
  ]
}

run "break_glass_identity_required" {
  command = plan

  variables {
    break_glass_usernames = []
  }

  expect_failures = [
    var.break_glass_usernames,
  ]
}

run "cannot_fail_open" {
  command = plan

  variables {
    break_glass_usernames = ["platform-break-glass"]
    failure_policy        = "Ignore"
  }

  expect_failures = [
    var.failure_policy,
  ]
}
