# volume-protection-policy

## Purpose and scope

Installs one cluster-scoped `ValidatingAdmissionPolicy` and binding that deny PVC
deletion and protection-label removal for PVCs labeled
`platform.harvester.io/protected=true`. Provides enforcement that survives removal
of the volume Terraform configuration. Does not create PVCs, label workloads, grant
break-glass RBAC, configure audit alerting, or manage backups.

## Requirements and providers

| Dependency | Declared constraint / requirement |
| --- | --- |
| Terraform | `>= 1.3`; mocked tests require 1.7+. |
| `hashicorp/kubernetes` | `~> 2.38` (>= 2.38.0, < 3.0.0) |

Configure the Kubernetes provider in the caller. `kubernetes_manifest` requires a
reachable API server at plan time, so this module cannot be planned offline against
a real provider. The cluster must serve `admissionregistration.k8s.io/v1`
`ValidatingAdmissionPolicy` and `ValidatingAdmissionPolicyBinding`, and the applying
identity needs permission to manage both cluster-scoped resources.

Install once per cluster, before protected PVCs exist, from foundation state that
is separate from volume and application state.

## Default context

The policy and binding are named `protect-harvester-persistent-volumes` and
`failure_policy` is fixed at `Fail`, so evaluation problems block PVC update and
delete instead of allowing them. Only `break_glass_usernames` must be supplied.

Scope is cluster-wide and not configurable here: the binding matches all PVC
`UPDATE` and `DELETE` requests in every namespace, though only PVCs labeled
`platform.harvester.io/protected=true` are denied. Install one instance per
cluster, before protected PVCs exist, from state separate from volume and
application state. Override `policy_name` only to avoid a naming collision;
renaming an installed policy is a replacement blocked by `prevent_destroy`.

## Usage

Caller configuration snippet, **not a standalone root module**: declare and supply
all referenced variables and configure the provider separately. The source path
assumes the caller is at the **repository root**; adjust it elsewhere.

```hcl
module "volume_protection_policy" {
  source = "./modules/volume-protection-policy"

  break_glass_usernames = var.break_glass_usernames
}
```

Usernames must match `request.userInfo.username` exactly, as the API server reports
it; a service account uses the form `system:serviceaccount:<namespace>:<name>`.
Supply only audited emergency identities. Never include routine Terraform, CI,
operator, or administrator identities used for day-to-day work. Admission bypass
is not RBAC: those identities also need PVC update/delete permission granted
separately.

## Inputs

| Name | Type | Required / default | Meaning |
| --- | --- | --- | --- |
| `policy_name` | `string` | `"protect-harvester-persistent-volumes"` | Shared cluster-scoped policy and binding name; renaming can require replacement, blocked by `prevent_destroy` while configured. |
| `break_glass_usernames` | `set(string)` | Required, non-empty | Exact `request.userInfo.username` values allowed to bypass. Blank-only and whitespace-padded values are rejected; matching is by authenticated username, not group or credential/token value. Use the actual API-server username, including service-account identity format where applicable. |
| `failure_policy` | `string` | `"Fail"` | Must remain `Fail`; the module rejects any other value. |

## Outputs

| Output | Meaning |
| --- | --- |
| `policy_name` | Installed `ValidatingAdmissionPolicy` name. |
| `binding_name` | Installed `ValidatingAdmissionPolicyBinding` name. |
| `protected_label` | Enforced protection label key, matching the label applied by `../protected-volume`. |

## Behavior and limitations / lifecycle

- The binding uses `Deny` with empty `matchResources`, so the policy evaluates
  cluster-wide for PVC `UPDATE` and `DELETE`. Unlabeled PVCs are unaffected.
  Protected PVCs may be updated only while preserving the label value `true`.
  `CREATE` is not intercepted, so the label is not mandatory for new PVCs.
- `failurePolicy: Fail` means evaluation problems block PVC update/delete rather
  than silently allowing them. Verify the generated expression and behavior in a
  sandbox before enforcing in production.
- Break-glass usernames are rendered into the CEL expression in sorted order to
  keep diffs stable. The policy only authorizes names at admission; RBAC must
  separately grant those identities PVC update/delete. Restrict, monitor, and
  periodically review them, and require approvals plus a documented ticket.
- Both resources use `prevent_destroy = true`. This is **not absolute**: the rule
  lives in configuration, so removing the module/resource configuration removes
  the guard, and a sufficiently privileged identity can change or delete the policy
  and binding directly. The enforceable boundary is outside this state: withhold
  `update`/`delete` on `validatingadmissionpolicies` and
  `validatingadmissionpolicybindings` from routine identities, alert on audit
  events for these objects, and require separation of duties for retirement.
- Deleting or disabling the policy while protected PVCs exist removes protection
  immediately. Retire it only as an approved break-glass change with evidence that
  no protected PVC remains. It is not a backup or data-integrity control: it matches
  PVC operations, not backend data destruction, PV operations, or namespace deletion
  requests. Controller-issued deletes of labeled PVCs are still subject to admission
  and can block cleanup; unprotected VM-owned disks are outside this label-based guard.
- Decommissioning a protected volume uses `../protected-volume`: verify consumers
  and backups, relinquish Terraform ownership without deletion, remove matching
  configuration, then remove the label and delete the PVC as the break-glass
  identity and preserve audit evidence.

## Testing

Run from `modules/volume-protection-policy` with Terraform 1.7+:

```sh
terraform init -backend=false
terraform validate
terraform test
```

Tests use a mocked provider and pin the exact generated CEL string, match
constraints, deny action, and fail-closed setting. They catch regressions but do
not prove the API server accepts or enforces the expression; run sandbox checks
for allowed updates, denied deletions and label removals, and a verified
break-glass path against the target Kubernetes version. Provider installation
requires registry access or a configured mirror/cache.
