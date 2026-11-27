# ADR-0046 — Own-model scoring for consented staging pairings

Proposed in #1144. Independent code and security review precede rollout.

## Context

The existing staging analyzer authorizes a single synthetic device and an expiring fixture window. That path supports isolated model experiments. A second consented staging family needs the same Stockholm own-model scoring during shared handset QA.

## Decision

A separate default-off staging mode permits scoring from paired devices after the API checks active consent against the family's jurisdiction, the app's stored opt-in, the supported capture source and the 1,024-byte text limit. Requests use the existing private analyzer endpoint. Only the Stockholm own-model configuration accepts this mode, including at the collector and its in-process CPU route. The API and collector must agree on the request mode. A mixed-version or mixed-configuration rollout falls back to local rules.

Atomic Redis reservations apply a per-family local-day cap and a global UTC-day cap. Cap refusal or counter unavailability leaves local scoring available. Warnings carry counts and reason only. Both paths use the existing vault and receipt shapes.

Remove `OSRA_STAGING_AI_ALL_CHILDREN` from the API and analyzer to disarm this mode. The API refuses the setting outside staging. The temporary fixture path retains its existing authorization and provider controls.

## Alternatives and consequences

Renewing separate single-device windows would keep restricting concurrent families and require coordinated task restarts during testing. Extending the new mode to a hosted provider would change the approved data route. This change keeps broader staging intake on the Stockholm own model. It adds an operational dependency on Redis and can conservatively spend a reservation when a response times out. The standard live checks and signed two-family device evidence are separate from the automated routes.

