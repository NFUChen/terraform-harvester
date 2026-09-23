locals {
  protected_label = "platform.harvester.io/protected"
  break_glass_cel = join(", ", [
    for username in sort(tolist(var.break_glass_usernames)) : jsonencode(username)
  ])

  # Protected PVC rules:
  # - ordinary users may update a protected PVC only while preserving the
  #   protection label;
  # - ordinary users may not delete a protected PVC;
  # - only exact, audited break-glass usernames bypass the rule.
  protection_expression = format(
    "request.userInfo.username in [%s] || !has(oldObject.metadata.labels) || !(%s in oldObject.metadata.labels) || oldObject.metadata.labels[%s] != 'true' || (request.operation == 'UPDATE' && has(object.metadata.labels) && %s in object.metadata.labels && object.metadata.labels[%s] == 'true')",
    local.break_glass_cel,
    jsonencode(local.protected_label),
    jsonencode(local.protected_label),
    jsonencode(local.protected_label),
    jsonencode(local.protected_label),
  )
}

resource "kubernetes_manifest" "policy" {
  lifecycle {
    prevent_destroy = true
  }

  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicy"
    metadata = {
      name = var.policy_name
    }
    spec = {
      failurePolicy = var.failure_policy
      matchConstraints = {
        resourceRules = [{
          apiGroups   = [""]
          apiVersions = ["v1"]
          operations  = ["UPDATE", "DELETE"]
          resources   = ["persistentvolumeclaims"]
        }]
      }
      validations = [{
        expression = local.protection_expression
        message    = "Protected PVC cannot be deleted or have platform.harvester.io/protected removed. Use the audited break-glass decommission workflow."
        reason     = "Forbidden"
      }]
    }
  }
}

resource "kubernetes_manifest" "binding" {
  lifecycle {
    prevent_destroy = true
  }

  manifest = {
    apiVersion = "admissionregistration.k8s.io/v1"
    kind       = "ValidatingAdmissionPolicyBinding"
    metadata = {
      name = var.policy_name
    }
    spec = {
      policyName        = kubernetes_manifest.policy.object.metadata.name
      validationActions = ["Deny"]
      matchResources    = {}
    }
  }
}

output "policy_name" {
  description = "Installed ValidatingAdmissionPolicy name."
  value       = kubernetes_manifest.policy.object.metadata.name
}

output "binding_name" {
  description = "Installed ValidatingAdmissionPolicyBinding name."
  value       = kubernetes_manifest.binding.object.metadata.name
}

output "protected_label" {
  description = "Label enforced by this policy and emitted by protected-volume."
  value       = local.protected_label
}
