# volume-protection-policy

Cluster-level hard deletion protection for PVCs created by the companion
`protected-volume` module.

Terraform `prevent_destroy` exists only in configuration. If somebody removes
the entire module/resource block, Terraform no longer sees that lifecycle
rule. This admission policy is the independent control that survives
configuration removal.

## What it enforces

For PVCs labeled:

```text
platform.harvester.io/protected=true
```

ordinary Kubernetes identities cannot:

- delete the PVC;
- update the PVC to remove or change the protection label.

The policy uses `failurePolicy: Fail` and a binding with `Deny`. Exact,
audited break-glass usernames are the only bypass.

## Install once per cluster

Deploy from a platform/foundation state separate from application and volume
states:

```hcl
provider "kubernetes" {
  config_path = var.kubeconfig
}

module "volume_protection_policy" {
  source = "./modules/volume-protection-policy"

  break_glass_usernames = [
    "platform-break-glass",
  ]
}
```

Do not include the normal Terraform service account, CI identity, VM operator,
or human administrator identities used for routine work in the break-glass
list.

## Break-glass identity requirements

The identity should:

- be disabled or inaccessible during normal operation;
- require MFA/short-lived credentials where the identity provider supports it;
- emit auditable API-server events;
- require data-owner and platform approval;
- have a documented incident/decommission ticket;
- be reviewed periodically.

The policy authorizes the username at admission time. Kubernetes RBAC must
still grant the break-glass identity PVC update/delete permissions.

## Decommission sequence

1. Verify no VM, VMI, Pod, or VolumeAttachment consumes the volume.
2. Verify backup and restore procedure.
3. Remove the volume from Terraform state without destroying it.
4. Remove it from root configuration.
5. Using the break-glass identity, remove the protection label.
6. Delete the PVC.
7. Preserve audit evidence.

See `../protected-volume/README.md` for exact commands and the complete
runbook.

## Compatibility

Requires a Kubernetes API server supporting
`admissionregistration.k8s.io/v1` `ValidatingAdmissionPolicy` and
`ValidatingAdmissionPolicyBinding`. Harvester provider 1.9.0 targets modern
Kubernetes, but verify the cluster API before rollout:

```sh
kubectl api-resources | grep ValidatingAdmissionPolicy
```

## Rollout safety

Before enforcing in production:

1. Render and inspect the generated CEL expression.
2. Test against unprotected PVC create/update/delete in a sandbox namespace.
3. Test that a protected PVC update preserving the label succeeds.
4. Test that normal delete and label removal are denied.
5. Test that the audited break-glass identity can remove the label and delete
   a disposable protected PVC.
6. Confirm policy/binding are managed by a foundation state with restricted
   write access.

Do not delete or disable this policy while protected PVCs exist.

The policy and binding carry `prevent_destroy = true`, so an ordinary
`terraform destroy` in the foundation workspace cannot remove PVC protection
while this module remains configured.

That lifecycle rule has the same structural limit as the one on the volumes
themselves: it lives in configuration. If somebody deletes this module block,
Terraform stops evaluating the rule and can then destroy the policy and
binding. Protecting a Terraform resource with more Terraform is circular — the
same identity that can edit this code and state can remove whatever guard is
added here.

The enforceable boundary therefore has to sit outside this state:

1. **RBAC.** The Terraform identity used for day-to-day platform work must not
   hold `delete`/`update` on `validatingadmissionpolicies` or
   `validatingadmissionpolicybindings`. Grant that only to a separate
   break-glass identity, managed from a different, more restricted state or
   by cluster administrators.
2. **Detection.** Alert on API-server audit events for delete/update of this
   policy and binding. If prevention is bypassed by someone with sufficient
   privilege, that must page a human immediately.
3. **Separation of duties.** Policy retirement should require approval from a
   role that cannot also approve the corresponding data deletion.

Retiring the policy legitimately is a break-glass change: remove the lifecycle
blocks under review, or perform an approved state/`kubectl` operation, with
evidence that no protected PVC remains.

The bundled tests use a mocked provider and pin the exact generated CEL string
and match constraints, which catches regressions but does not prove the API
server accepts or enforces the expression. Run the sandbox rollout checks above
against the target Kubernetes version before enabling this in production.

## Verification

```sh
terraform fmt -recursive -check
terraform validate
terraform test
```
