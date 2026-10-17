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

## Writing a new ADR

1. Copy the shape of an existing one; number it `NNNN-short-title.md`.
2. State the **context and forces** honestly (including deadlines and constraints like "free GitHub
   plan", "no Mac in CI", "testers on LAN").
3. List the alternatives you actually considered, and why you rejected each.
4. Record the **consequences, including the bad ones** — an ADR without costs is marketing.
5. If evidence changed your mind later, do not edit history: add a new ADR that supersedes this one.
