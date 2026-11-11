### Child agent (Android) — the phone describes itself: its build on every request, its capabilities in telemetry and at claim time (ADR-0034 PR 2)
- **What a parent gets:** a Phone setup screen that shows what this phone can *actually* do, fixed the moment a
  grant is fixed, instead of a checklist the server has to guess at. Nothing here is visible as a new button; it
  is what makes the existing setup screen honest.
- **`X-OSRA-Client` on every request** (decision 4, amendment A3): `child-android/<a>.<b>.<c>+<build> (<flavour>)`,
  computed by `ClientHeader` from `BuildConfig`. The Play and Full artefacts report their own flavour. **A value
  that would not match the server's pattern is not sent at all** — a four-part or non-numeric version name, a
  part over four digits, no build number — because everything that does not match is legacy on the server and is
  served anyway, while a wrong build number would put a lie in front of the update gate. A two-part name is
  padded (`0.2` → `0.2.0`), which Gradle allows and the wire does not.
- **The capability report is computed on the phone, never derived on the server** (decision 1):
  `CapabilitiesPolicy` builds it from primitives, so every rule is a JVM row. Three rules that are easy to get
  backwards and are pinned:
  - **`ready` needs the working path, not the grant.** The lock is deferred to
    `EnforceabilityPolicy.lockOutcome`, so a granted overlay with the accessibility service off is still
    `unavailable` — the #368 rule that an overlay-only lock shows once and Home takes it away.
  - **a build that cannot do a feature omits the key** rather than claiming `not_supported`, which is the
    server's word from its static table. The Play artefact therefore says nothing about notification scan or the
    call/sms log, and its notification-access grant is `not_applicable`, not `missing`.
  - **a weaker path the agent still serves is `degraded`** — a filter with consent but no tunnel, and location
    without background access, are both still answered on the phone.
- **`profiles` (osra-security#6 item 2)** rides the report when `ProfileReader` could read it, and is absent when
  it could not: an absent field leaves the stored value alone, so an older agent never erases what a newer one
  said.
- **It travels on both surfaces**: every telemetry upload (periodic, expedited, and the location-grant report)
  carries `capabilities`, and so does `POST /v1/devices/pair/claim`, so a phone is described from its first
  minute (A2). The server validates it strictly and on its own, so a bad report costs the field and not the
  telemetry beside it.
- **A grant change costs one request, not one per resume** (A2): `UsageReporter.reportCapabilitiesIfChanged()`
  uploads only when the report's **fingerprint** differs from the last one the server accepted, and records the
  fingerprint only after a successful POST — a failed request is retried, never remembered as covered. The
  idle-request budget (#353/#367) is untouched: a resume with nothing changed sends nothing.
- **`GrantWire` writes the ten wire names out** instead of deriving them from the enum with `lowercase()`, so a
  Kotlin rename cannot invent a key the server's strict schema rejects; a row pins the pair in both directions.
- Rows: `ClientHeaderTest` (5), `CapabilitiesPolicyTest` (10), `GrantWireTest` (2),
  `CapabilityUploadPolicyTest` (3).
- **Not verified here:** nothing runs on the phone in this PR — the report is JVM-tested, and the two facts it
  depends on (`AccessibilityMonitorService.isRunning`, `VpnState.isEstablished`) are read, not changed. The phone
  pass should confirm a granted accessibility service flips `lock_screen` to `ready` on the parent's setup screen
  within one resume.
