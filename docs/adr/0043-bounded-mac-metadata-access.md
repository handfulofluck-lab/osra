# ADR-0043 — Bounded Mac infrastructure metadata access

- **Status:** proposed implementation record; independent current-head review and deployment prerequisites remain open
- **Date:** 2026-11-17
- **Owners:** Claude coordinates architecture; Kimi and Ahmed review the implementation; the maintainer owns console/MFA and access authorization
- **Related:** #887, #893; roadmap 5.8; the authoritative private security review

## Context

A separate Mac credential process needs its own principal, monitoring and fixed authorization period.
Initial access is limited to reviewed infrastructure metadata. Preparing or merging code does not
authorize credential creation, role use or cloud changes. The PC script and caller defaults remain unchanged. Boundary changes must preserve the original
unconditional key-creation deny and receive independent review.

## Proposed implementation

Use literal metadata actions rather than AdministratorAccess, a broad managed read-only policy or
wildcard read-action patterns. Account/resource-capable actions have explicit ARN scopes. Regions and
production role aliases are required reviewed inputs with no defaults. Separate deny ceilings constrain
the user and Mac SourceIdentity-attributed production sessions. The existing audit denies remain.

The Mac has no IAM write or rotation grant. The credential process reads one login-Keychain item;
both rotation entry points refuse before accessing storage or AWS. The owner creates the initial
principal and first key through the approved console/MFA procedure. An existing principal is imported
before an approved infrastructure apply; keys are not Terraform resources or state values.

Use a protected fixed-deadline tag, literal policy cutoffs and a scheduled all-current-key disable job.
The job has its own narrow execution boundary, restricted invocation and health alarms. Its diagnostics
contain status/counts only. A renewed tag alone does not renew installed literal cutoffs. Renewal is a
separate owner/MFA operation that reconciles every deadline and creates a new key.

Supply SourceIdentity explicitly on the approved agent entry path. Review the current role trust and
caller together; emitted trust statements are review material, not an applied trust change. Preserve
the existing PC/Identity Center caller defaults and legacy monitoring through the approved transition.

## Alternatives and costs

- AdministratorAccess and broad managed read-only policies do not express the initial metadata scope.
- A credential file duplicates material that belongs in login Keychain. The credential process avoids
  that copy, but processes under the same macOS login share the Keychain access boundary.
- Self-rotation does not renew authorization and is outside phase 1. Owner-managed replacement adds
  an operational step at renewal.
- Scheduled key disablement is cleanup, not exact-second STS revocation. Review the complete approved
  permission, timing and session procedure before use. AWS documents scheduled-rule minute resolution
  and session-policy evaluation separately.
- Literal action/resource inventories and policy-size budgets require review when infrastructure or
  scope changes. Metadata can contain sensitive operational identifiers; keep real outputs private.

## Falsifiable review claims

1. No Mac administrator attachment or rotation grant exists; Mac IAM writes/content reads are denied.
2. Only the literal metadata inventory, reviewed region/account resources and mapped entry role are
   allowed. Entry requires the Mac SourceIdentity after the proposed trust is installed/reviewed. The
   original boundary creation deny and additional stricter key guards are pinned separately.
3. Earlier audit-deny statements remain pinned. Policy limits are unchanged.
4. Expiry fakes process every current key, fail closed on invalid/missing deadlines and suppress raw
   SDK diagnostics. Literal guards deny at equality and require reconciled renewal.
5. Local fake/mock checks establish implementation behavior only. Independent policy/runtime identity,
   scope, deadline and alarm evidence is required privately before access can be enabled.

## Sources

- [SourceIdentity and monitoring temporary credentials](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_control-access_monitor.html)
- [Controlling permissions for temporary credentials](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_control-access_disable-perms.html)
- [IAM policy variable restrictions](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_variables.html)
- [EventBridge scheduled-rule resolution](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-create-rule-schedule.html)

Private review retains the actual mapping, approvals, simulator results and runtime evidence. This
record contains no deployment authorization and must not be used as a substitute for those checks.
