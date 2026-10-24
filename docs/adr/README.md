# Architecture Decision Records

Each ADR captures **one decision, the reasoning behind it, the alternatives that were rejected, and
what it costs us**. Code shows *what* we built; these show *why*, so a future contributor (or agent)
can tell a deliberate constraint from an accident — and can safely overturn a decision when its
context changes.

Format: Status · Context · Decision · Reasoning · Alternatives considered · Consequences · Evidence.
Status is one of `accepted`, `superseded by ADR-XXXX`, `deprecated`, or `proposed`.

| # | Decision | Status |
|---|---|---|
| [0001](0001-monorepo-and-platform-split.md) | One monorepo, native agents per platform, Flutter for the parent app | accepted |
| [0002](0002-server-authority-and-consent-gate.md) | The server is the authority: family isolation (403) and a consent gate (428) | accepted |
| [0003](0003-per-device-hmac-agent-auth.md) | Agents authenticate with per-device HMAC secrets, not a shared secret or bare JWT | accepted |
| [0004](0004-parent-session-hygiene.md) | Rotating refresh tokens with reuse detection, single-use WS tickets, optional MFA | accepted |
| [0005](0005-adversarial-acceptance-gate.md) | A separate adversarial probe suite as the merge gate | accepted |
| [0006](0006-content-monitoring-and-snippet-vault.md) | Bounded, encrypted snippets and concern alerts — not full-chat surveillance | accepted |
| [0007](0007-engineered-process-controls.md) | Process is engineered (hooks, lint, PR-only main, hardware verification), not promised | accepted |
| [0008](0008-parental-consent-lifecycle-and-revocation.md) | Parental consent lifecycle, revocation, and enforcement across child-scoped writes | accepted |
| [0010](0010-android-tamper-protection-tiers.md) | Android tamper protection: Device Admin tiers, parent PIN at pairing, accessibility guard over the OS removal screens, admin-removed alert | accepted |
| [0011](0011-parent-notifications-push-and-email.md) | Parent notifications: push (FCM/APNs) and email through one alert path; 0009/0010 reserved by the Android lane | accepted |
| [0012](0012-durable-device-command-queue.md) | Durable device command queue: delivery state, acks, per-type expiry, device-only drain | accepted |
| [0013](0013-usage-model-retention-and-erasure.md) | Durable usage model (`AppUsageDaily`, `WebVisit`), nightly rollup + retention, complete erasure cascade | accepted |
| [0014](0014-signing-v2-sessions-and-family-roles.md) | Signing v2 (timestamp + nonce, service callers), revocable parent sessions, enforced family roles, MFA secret at rest | accepted |
| [0015](0015-android-dns-sinkhole.md) | Android web filter as a local DNS sinkhole: DNS-only `VpnService`, SafeSearch/YouTube CNAME rewrites, pause-internet takes the default route, revocation is tamper | accepted |
| [0016](0016-play-vs-full-flavors-and-notification-capture.md) | Two Android flavors (`play`, `full`): `NotificationListenerService` and its permission live in `full` only, decision logic shared in `main`, manifest difference tested | proposed |
| [0017](0017-family-local-digest-time.md) | The weekly digest is sent at the family's local hour (`Family.timezone`, hourly wake, one send per week) | accepted |
| [0018](0018-shared-test-api-ownership.md) | The shared `:3000` test API is owned by the lead, serves `main@HEAD`, and runs outside agent task trees | accepted |
| [0019](0019-safe-direction-commands.md) | A command is safe-direction only if it can never start, extend or escalate a restriction | accepted |
| [0020](0020-family-timezone-setting.md) | The family timezone comes from the parent's device at signup/login and is a parent setting; `region` stays a market (B1) | accepted |
| [0021](0021-play-policy-review-child-agent.md) | Play policy review: call-log/SMS and `QUERY_ALL_PACKAGES` leave the `play` build, `isMonitoringTool=child_monitoring` is declared, the listener stays Full-only | accepted |
| [0022](0022-websocket-ticket-only.md) | WebSocket authentication is ticket-only; the legacy `?token=` handshake is removed (supersedes that clause of ADR-0004) | accepted |
| [0023](0023-mfa-recovery.md) | MFA recovery: one-time recovery codes at enrolment, with a support break-glass for the cohort that has none (support path superseded by ADR-0031) | accepted (technical half) |
| [0024](0024-digest-claim-failure-lifecycle.md) | A digest send claim outlives a permanent refusal (`DigestSend.failedReason`), not a transient one; the sender classifies `retryable` | accepted |
| [0025](0025-session-revocation-counter.md) | Parent session revocation is a monotonic counter (`sv` claim), not a second-grained `iat` epoch; a token minted in the revocation second is dead (#117) | accepted |
| [0026](0026-pip-split-overlay-coverage.md) | Multi-window coverage: judge every visible application window (PiP and split), expand the overlay with `resizeableActivity=false`, bound the re-raise; PiP itself cannot be closed by an accessibility service (#175) | accepted |
| [0027](0027-tamper-alert-idempotency.md) | Tamper alerts are edge-triggered and idempotent: admin removal carries `<device>|<type>|<disable timestamp>` to a partial unique index; accessibility-off alerts only on a recorded on → off transition (#225) | accepted |
| [0028](0028-hosting-regions-and-scaling.md) | Production hosting: managed containers on AWS, one independent stack per region in launch order (regions superseded by ADR-0030), push-first device wake-ups, capability list and version gate, cost model 1k–1M families | accepted |
| [0029](0029-repeated-remove-attempts-aggregate.md) | Repeated remove-protection attempts are one alert row per 5-minute window, updated in place with a count; the first attempt still pages immediately (#227) | proposed |
| [0030](0030-regions-after-uae-outage.md) | Regions after the AWS UAE outage: production's first region is Frankfurt (serves the Middle East launch), staging in Stockholm, nothing built in `me-central-1`; supersedes ADR-0028's region table | accepted |
| [0031](0031-mfa-reset-family-witness.md) | MFA reset when every recovery code is gone: password, mailbox, a family witness (a code on a paired child device or another parent's approval) and a 72-hour window that any sign-in cancels; no support operator; supersedes ADR-0023's open support path (#297) | accepted |
| [0032](0032-durable-revocation.md) | Revocations are stored in Postgres (`Parent.sessionVersion`, `RevokedToken`, the `Device` row) and Redis is only a cache that rebuilds on a miss; ElastiCache pins `noeviction` and keeps one daily snapshot (roadmap 2.7) | accepted |
| [0033](0033-production-message-scoring.md) | A real child's message is scored only on Amazon Bedrock inside the EU (Frankfurt in-region, the EU profile, or another EU region), with AWS data retention set to `none`; the model is the cheapest that passes the Phase 4 gate on the held-out split twice; DeepSeek's own API stays eval-only; our own model (4.4) is the scale path (roadmap 4.1/4.4) | proposed |
| [0034](0034-capability-report-and-version-gate.md) | Each device reports what it can enforce (grants, plus features computed by the agent's own acknowledgement policies) on telemetry and at pairing, and every client names its build in `X-OSRA-Client`; a parent app below the minimum gets 426, an old child agent is never refused, and a keyguard-only lock counts as `unavailable` (roadmap 5.8 items 1 and 2, #368) | accepted |

## Writing a new ADR

1. Copy the shape of an existing one; number it `NNNN-short-title.md`.
2. State the **context and forces** honestly (including deadlines and constraints like "free GitHub
   plan", "no Mac in CI", "testers on LAN").
3. List the alternatives you actually considered, and why you rejected each.
4. Record the **consequences, including the bad ones** — an ADR without costs is marketing.
5. If evidence changed your mind later, do not edit history: add a new ADR that supersedes this one.
