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
| [0011](0011-parent-notifications-push-and-email.md) | Parent notifications: push (FCM/APNs) and email through one alert path; 0009/0010 reserved by the Android lane | accepted |

## Writing a new ADR

1. Copy the shape of an existing one; number it `NNNN-short-title.md`.
2. State the **context and forces** honestly (including deadlines and constraints like "free GitHub
   plan", "no Mac in CI", "testers on LAN").
3. List the alternatives you actually considered, and why you rejected each.
4. Record the **consequences, including the bad ones** — an ADR without costs is marketing.
5. If evidence changed your mind later, do not edit history: add a new ADR that supersedes this one.
