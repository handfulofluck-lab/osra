# ADR-0046: Access-request alerts and parent approval

Status: accepted

## Context

A child can tap Request access on the Android block screen, but the parent alert did not open a useful detail or offer a decision. Alerts also displayed a raw package name instead of the app’s friendly name and icon. The existing API already supports rules changes and alert acknowledgement, so a new request table and child-facing decision route are unnecessary.

Claude approved the behavior on #1094, with EN and Arabic copy supplied by the UI/UX and Arabic Bureaus. The implementation covers #1094 and #1095 together because they share the producer metadata, identity resolver, alert presentation and action flow.

## Decision

1. Android alert metadata is additive. Automatic blocked attempts carry `appName` but no request marker; access requests carry `appName` and `requestType: "access"`. Existing category, `packageId`, reason and body fields remain compatible. Each producer snapshots the label before starting asynchronous work so a reused activity cannot pair one package with another app's label. The parent recognizes legacy requests only when the title is exactly `Access requested` and no `requestType` exists.
2. App identity resolves in this order: the alert device's latest installed-app report (label and icon), meaningful metadata `appName`, then package id. A child-wide merged report is only a fallback when the device is unknown. The raw package is a last-resort visible fallback, never the preferred label.
3. Child Alerts and top-level Alerts open the existing general alert detail for `app_blocked`. Ordinary blocked attempts have no actions. Unanswered access requests use an info/blue raised-hand treatment and pin ahead of day groups; they are never presented as red failures. An opened detail watches refreshed alert data, using its navigation snapshot only while loading or when the alert is no longer in the authorized feed.
4. **Allow writes `appRules: allow`, not `alwaysAllowedApps`.** Bedtime, school time and Pause still apply. Deny means Keep blocked and changes no rule. `acknowledged` is the resolved state: Allow saves the rule first and acknowledges only after success; Deny acknowledges only. Failed saves keep the actions and show an inline error. Actions fail closed until family permissions load. Owners can perform both; co-parents need `rules` and `alerts` for Allow and `alerts` for Keep blocked; guardians need both permissions for either action.
5. The API contract is the existing rules PATCH and alert ACK. No InstallRequest route, child-decision route, new table, or second request state machine is introduced.
6. EN and AR use the Bureau copy exactly, with 48/52 dp targets, the approval disclosure visible only while unanswered, and named states for saving, resolved, error, co-parent resolution, legacy resolution and read-only guardian. A resolved line stands alone without repeating the approval disclosure. Resolution metadata reconciles when a refreshed alert arrives. `firstStrongIsolate` protects child/app names; package fallback uses `ltrIsolate`.

## Reasoning

A single tap from an alert should not silently create a permanent exemption. Using the normal app-rule permission preserves scheduled controls while resolving the immediate request. Existing acknowledgement is enough to hide actions and return the row to time order, avoiding a parallel lifecycle that could diverge from the rules and alert feed.

Metadata makes the request explicit instead of inferring it from a raw English body. The narrow title fallback keeps already-persisted requests usable without turning every blocked attempt into an actionable request.

## Alternatives considered

- **Permanent `alwaysAllowedApps`:** rejected because it overrides routines and Pause, which a single alert tap must not silently do.
- **A new InstallRequest backend:** rejected as unnecessary lifecycle duplication; the existing rule write and ACK already express the decision.
- **Actions on every `app_blocked` row:** rejected because ordinary blocked attempts require no parent action.
- **Inferring requests from the English body:** rejected because localization and custom payloads make it brittle; only the exact legacy title is supported.

## Consequences and costs

- Older clients that ignore the additive metadata keep the original body; current clients render localized identity instead of that raw body.
- A legacy acknowledged request has no recorded decision outcome, so the UI says it was handled rather than inventing allowed/denied history.
- Allow does not bypass routines or Pause, so a child may still be blocked later; the always-visible disclosure is required to prevent a misleading promise.
- Rules write and ACK are two non-atomic calls. The UI therefore ACKs only after a successful rule save and leaves retryable actions on failure instead of claiming resolution.

## Evidence

Implementation and verification are in progress on `kimi/1094-access-request-alerts`. Required evidence includes Android producer metadata, Child/top-level navigation, legacy/current recognition, ordinary non-actions, save-before-ACK ordering, failed-save behavior, deny without rule mutation, identity/icon fallback, EN/AR narrow layouts and the full Bureau state/frame matrix. Final results belong in PR comments, not asserted here in advance.
