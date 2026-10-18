# Changelog

All notable changes to OSRA are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/),
versioning follows the product milestones rather than strict SemVer (this is pre-1.0 software).

Entries are grouped by the day the change landed on `main`, with the PR/issue references that carried
it. Anything marked **⚠️ not verified here** was written by an agent but could not be verified in the
environment where it was written — see `docs/QA/` for the verification state.

---

## [Unreleased]

### QA — `qa-probe` stops on a 429 burst instead of recording it as product failures (issue #112)
- **A rate-limited run now aborts instead of failing dozens of checks.** `services/api/scripts/qa-probe.mjs`
  counts 429s in `call()`; the first 429 it cannot retry prints
  `ABORT: rate limited by the API (<n> x 429) - wait 60 s and re-run` and exits **2**, without recording a
  429-induced check as a failure. Exit 1 still means a real assertion failure.
- The counter aborts when one run sees **more than 5** 429s. Five is the issue's suggestion and matches the
  measured shape (66 throttled responses in the #112 report, 27 phantom failures); the probe makes ~109
  calls, so a smaller number would turn one unlucky overlap with another agent's run into an abort.
- One retry is honoured only when `Retry-After` is ≤ 3 s. The API's limiter answers with 57–60 s windows,
  so in practice the probe stops rather than sleeping through the window; a retry that also 429s aborts.
- The summary line now ends `· rate limit: N x 429`, so a reader of a green run can see the run was not
  throttled; a completed run with N > 0 says the retries succeeded.
- **Measured (2026-10-18, shared `:3000`):** three concurrent probes → all three exit 2 with
  `(2 x 429)`; the API log holds 6 distinct 429 responses (`Rate limit exceeded`) and the probe counts sum
  to 6 — no `FAIL` line in any run. A clean run afterwards: **109 passed · 0 failed · 0 targets · 0 notes**.
- Test: `test/qa-probe-rate-limit.test.ts` points the real probe at a stub that only answers 429 and
  asserts the abort contract (both cases fail on `main`, pass here). Probe integrity unchanged:
  `check=88 target=1 note=1`.
### API — audit findings 4–6: the silence watch fires, device telemetry is self-scoped, push-token stops leaking the HMAC secret
- **Finding 4 — the device-silence watch watched a value nothing writes.** `src/jobs/deviceSilence.ts`
  selected and ruled on `status === "active"`, but every writer stores `online` (pair/claim
  `routes/devices.ts:187`, telemetry `:331`, location ping `routes/location.ts:239`, seed
  `scripts/seed.ts:60`); the schema default and the job itself write `offline`, and `DeviceStatus`
  (`packages/shared-types/src/index.ts:10`) is `online`/`offline`/`locked`/`sos`. The watch therefore
  matched no device, and the `pm clear` mitigation it was built for did not run. It now watches
  `online`; the schema field documents the vocabulary. The regression test starts from a real
  `POST /v1/devices/:id/telemetry`, captures the status the route persists, replays that row through
  the job's `where` clause and asserts the critical `tamper` / `device_silent` alert and the flip to
  `offline`; it also asserts one alert per episode (the second instance is suppressed by the claim) and
  that a fresh telemetry report re-arms the watch for the next episode. The pure rule keeps an explicit
  negative case for the stale `"active"` value.
- **Finding 5 — a device JWT could write a sibling's telemetry/activity.** `POST /:id/telemetry` and
  `POST /:id/activity` were family-scoped only (`requireFamily`), so device A could refresh sibling B's
  `lastSeen`/`status`, battery and day totals, and insert activity rows under B. A shared
  `requireOwnDevice` preHandler (`middleware/requireFamily.ts`) now composes after `requireFamily` on
  both routes, so a future agent-write route can reuse it instead of repeating the omission. Device
  tokens require `user.deviceId === id` (403 otherwise), matching `GET /:id` and the command routes;
  parent tokens remain family-scoped. Tests: A→B 403 (no usage row and no `live_activity` frame when
  the batch would otherwise publish one), A→A 202, parent→either 202, cross-family 403 for both routes.
- **Finding 6 — `POST /:id/push-token` returned the whole Prisma row**, including `internalSecret` (the
  per-device HMAC secret) and the push token. The update now reads an explicit allowlist (`select` —
  a secret column added later is not returned by accident) and then passes it through
  `sanitizeDevice`, the helper the list/single GET and `/family/me` already use. It also requires
  `requirePermission("devices")`, the same gate as `command` and unpair, so a co-parent admitted
  without that tag cannot repoint a child's notifications. Tests: the response has neither key and
  the `select` names neither; a co-parent without `devices` gets `403 permission_required` and no
  write, with the tag it succeeds.
- **Verification** (author's run): `pnpm --filter @familyshield/api test` — 318 passed / 29 files;
  `node scripts/check-probe-integrity.mjs --base origin/main` — 88/0. **Not verified here:** no
  live-stack `qa-probe` row was added for these three findings — the probe file is held by a sibling
  lane, and the gate checks are deliberately deferred to the lead's follow-up PR (stated in the PR so
  the deferral is visible). No hardware row applies.
### Parent app — command delivery status is the queue's real state (plan 3.6, #116)
- The child detail device card now shows the **latest command's queue state** and opens
  **Command delivery** (`/child/:id/commands`): a per-device list read from
  `GET /v1/devices/:id/commands/history`, with `pending`, `delivered`, `acked`, `failed` and
  `expired` states and the creation / delivered / confirmed times the server recorded.
- **The acceptance line:** an unacked command is never called "sent". `delivered` is labelled
  "Delivered — awaiting device confirmation", `pending` is "Pending — waiting for the device", and
  only `acked` says "Confirmed by device". The existing Ring/Lock/… and pause toasts (child detail
  and map) changed from "sent to … — reaches the device within ~1 minute" to "queued for … — the
  device has not confirmed it yet", because `POST /v1/devices/:id/command` only creates a `pending`
  row (`services/api/src/routes/devices.ts:245`).
- Empty and error states are explicit per device ("No commands yet"; "Could not load command
  history" with Retry). The screen is registered in the app router and has a widget test that taps
  the device-card action through a real `GoRouter`; a 320×568 layout test covers the new screen.
- `flutter test`: **112 passed** (7 new in `test/command_history_test.dart`); `flutter analyze`:
  **No issues found**. Author run (Kimi Code); independent verification is still owed (WO-03).
  The response shape was checked against the live stack
  (`GET /v1/devices/78593c53…/commands/history` → `{items:[{status, createdAt, deliveredAt, ackedAt, …}]}`,
  dates as ISO strings).

### QA — the F8 revocation check no longer races the clock (issue #110)
- `qa-probe` F8 failed once and passed on re-run with identical code: the check waited a flat 1100 ms before
  re-logging in, but `iat` has **one-second resolution**, so a login could still land in the revocation
  epoch and be revoked on arrival. It now waits for the wall clock to **cross a second boundary**
  (`waitForNextSecond`) and asserts the **cause** — the fresh token actually works against
  `GET /v1/family/me` — instead of trusting the instant of the login. The evidence line gained
  `freshTokenUsable=…`, so a future failure names which half broke.
- Three consecutive probe runs after the change: F8 PASS each time, **109 passed · 0 failed**. The issue's
  acceptance (twenty consecutive runs) is left to CI/Antigravity with the command in the issue.

### Parent app — the digest timezone is a setting, not a hidden default (ADR-0020, plan 2.2)
- **Digest preferences now shows and sets the family's timezone** (a curated list of the markets OSRA ships
  to, UTC included), reads it from `GET /v1/family/me`, and saves a change with `PATCH /v1/family/me`.
  The screen says what the setting means: "the digest is sent at 18:00 your local time".
- Choosing a zone makes it the **parent's** choice server-side (`timezoneSource = parent`), so no device
  login can move it again (#101, guard corrected in #105). Before this, a family could only be filled by
  whichever device logged in.
- Test: a widget test asserts the zone loads, the explanatory line renders, and picking a new zone sends
  exactly one `PATCH` with that value. Parent-app suite: **105 tests, all passing**.
- **Fixed before it shipped to anyone (issue #108):** a family whose zone is outside the curated list
  would have seen `UTC` in the dropdown while the server kept the real value. The control now always
  includes the family's actual zone as an option (`_zoneOptions`), with a test using `Asia/Tokyo`.

### Architecture — ADR-0020 correction: the device fill is guarded by `timezoneSource = 'default'` (2026-10-18)
- The first amendment's test wording (`<> 'parent'`) let every login re-fill the zone from the logging-in
  device. Decision 4 always said "only while the source is `default`"; the wording now matches. The code
  change is tracked on #101.

### Architecture — ADR-0021 and ADR-0020 amended after review on #96 (2026-10-18)
- ADR-0021: the `play` `<queries>` also declares the two dialer intents, so the #83 emergency-dialer
  exemption still resolves handlers without `QUERY_ALL_PACKAGES`. The manifest test asserts them and
  `isMonitoringTool` in both flavors, and S1 runs on the Play build too.
- ADR-0020: the login fill's tests are named, and the device zone is recorded as a coarse signal only.

### API — the digest is due at the family's local hour (ADR-0017, plan 2.2)
- **`Family.timezone`** (IANA, default `UTC`) and a `DigestSend(familyId, kind, period)` table with a unique
  key; migration `0014_family_timezone_digest_send`. The backfill is UTC **by construction**: `Family.region`
  is a market (`US/EU/UK/OTHER`), not a country, so there is nothing to map — recorded as Amendment B1 in
  the ADR rather than pretended.
- **`src/lib/digestSchedule.ts`** is the pure clock: local calendar fields and ISO week per family zone,
  "at or past `DIGEST_HOUR`" selection (default 18 **local**), so a DST spring-forward that deletes the
  configured hour sends at the next one instead of skipping the day, and a repeated fall-back hour resolves
  to one period. `isoWeekKey` uses the family's local date, so a Sunday-evening send cannot land in the
  next ISO week (Amendment B2).
- **The claim is the database row**, not a Redis `SET NX`: `runDigestsDue` inserts `DigestSend` before the
  email, skips on `P2002`, and deletes the row when the provider refuses so the next tick retries. A
  restart, two API instances or a clock repeat can no longer double-send.
- **Tests:** 11 cases in `test/digest-schedule.test.ts` (Dubai/UTC at 14:00Z and 18:00Z, Kiritimati/Pago
  Pago weekdays, London DST both directions, year-boundary ISO week) plus the scheduler claim test in
  `test/email.test.ts`. Full API suite: 28 files / 309 tests / 0 failures.
- **Not done here:** the parent-app setting that chooses the zone (3.x, as the ADR says); until it ships,
  every family is on UTC and the digest arrives at 18:00 UTC.
### Architecture — ADR-0020 family timezone source, ADR-0021 Play policy review of the child agent (2026-10-18)
- Decisions only, no code (work orders C1 and C2 on #92). ADR-0020 answers B1: `region` stays a market and
  consent jurisdiction; `Family.timezone` is filled from the parent's device at signup/login (never over a
  parent's own choice) and editable in settings. ADR-0021 finds that the `play` build inherits `READ_CALL_LOG`
  and `READ_SMS`, which Play does not permit for parental control, and moves them (with `CommsLogger`) to
  `full`; adds `isMonitoringTool=child_monitoring`; replaces `QUERY_ALL_PACKAGES` in `play` with a launcher
  `<queries>`; keeps the notification listener Full-only.
### Process — roles re-cut, 15/30-minute board cadence, roadmap and documentation rules (2026-10-17)
- Maintainer re-cut the roles: Kimi develops, Claude owns architecture and does constructive testing with
  fix guidance, Antigravity tests and reports. `AGENTS.md` §12 adds: every PR names and moves its
  `docs/ROADMAP.md` row, docs land in the same PR, and every finding carries its fix.
- Board cadence shortened from 30/60 to **15/30 minutes** (`docs/QA/TESTING-STRATEGY.md` §4,
  `docs/QA/TEST-REQUESTS.md` header). `docs/COLLABORATION-ROADMAP.md` marked superseded.

### Architecture — ADR-0017 family-local digest, ADR-0018 shared test API ownership, ADR-0019 safe-direction rule (2026-10-17)
- Decisions only, no code. ADR-0017 is implemented in a later PR (plan 2.2 follow-up / 3.x); ADR-0018 settles the ownership half of #71; ADR-0019 records why `stop_ring` passes the consent gate and gives the rule for future commands.

### Android — two distribution builds, and the notification listener exists only in Full (ADR-0016, plan 2.6 second half)
- **`play` and `full` flavors.** `app/src/main/AndroidManifest.xml` declares neither
  `BIND_NOTIFICATION_LISTENER_SERVICE` nor a listener, so the Play artefact cannot read notifications at
  all; `app/src/full/AndroidManifest.xml` declares both and registers
  `services.NotificationCaptureService`. The judgement stays single-copy in `main`
  (`NotificationCapturePolicy`, shipped in part 1): the service is a thin adapter that maps a
  `StatusBarNotification` to the policy's `Snapshot`, checks consent (ADR-0008 §3 — a revoked agent keeps
  the listener bound but records nothing) and enqueues with `SOURCE_NOTIFICATION` into the existing scan
  queue. The Play build keeps the accessibility **screen** path and says so in onboarding (ADR-0016 §4).
- **`FlavorManifestTest`** pins the split from the text of both manifests plus the source location: the
  Play manifest must not contain the permission, the action, or the class name, and the Full manifest must
  require the system permission and register the class. A flavor split is exactly the kind of fact that
  regresses silently when someone "simplifies" a manifest.
- **Variant names are spelled out at every call site** — `ci.yml` (now `testPlayDebugUnitTest`,
  `testFullDebugUnitTest`, `assemblePlayDebug`, `assembleFullDebug`, `assemblePlayRelease`), the TR-07
  signing script (`assembleFullDebug`: hardware runs install the sideloaded build), `docs/TESTING.md`
  (suite table and CI table) and `README.md`. No aliases: a missing variant is a build error, not a
  silently different artefact.
- **Part 1 fixed while wiring part 2:** `NotificationCapturePolicy` passed `List<String?>` where
  `ScanQueuePolicy.fromNotification` takes `List<CharSequence?>`; the branch never compiled, so part 1 had
  not been built since that call was written. The upcast is now explicit and commented.
- **Not verified here:** the listener on hardware (grant the notification-access row in the Full build,
  then send a WhatsApp message and see one row in the scan queue, not two for its group summary). The
  unit suite covers the decision; the OS wiring is the hardware row.

### Security/safety — the lock no longer covers an OEM emergency dialer (issue #80, found by the Phase 1 gate)
- **Cause.** `LockEnforcementPolicy`'s exemption list was written against AOSP names
  (`com.android.emergency`, `com.android.dialer`, `com.android.incallui`) and matched with
  `startsWith`. The one device we test — a Samsung Galaxy Z Flip4 — runs
  **`com.samsung.android.emergency/.emergencydialer.view.EmergencyDialerActivity`**, which no prefix
  matched, so `AccessibilityMonitorService` re-raised `LockActivity` over the emergency dialer: on the
  gate run the dialer started and the lock was on top at 6 s *and* 11 s. The unit test passed because
  it asserted the platform's names, not the device's.
- **Fix.** Two mechanisms, deliberately asymmetric: the explicit list now names the Samsung, Google and
  AOSP call/emergency surfaces, and `isExemptPackage()` additionally matches the **segment** — any
  package with an `emergency`, `incallui` or `dialer` segment is exempt, so an OEM we have never seen
  still gets through. Segment equality rather than substring, so `com.example.emergencygame` is still
  locked.
- **Why the asymmetry.** Over-exempting a dialer costs one unlocked app; blocking an emergency call
  costs the call.
- **Verified:** two JVM cases — a 14-row OEM table (including the exact Flip4 dialer) asserting the lock
  stays off, and a five-row negative table (`com.whatsapp`, `com.example.emergencygame`, …) asserting
  ordinary apps are still locked. Hardware re-run of probe row **S1** is the acceptance on the handset
  and is recorded on #80 when it passes; until then #78 stays held.
- **The gate itself was measuring the wrong thing (found while re-running S1, same day).** `lock` is a
  real `lockNow()`, so on a phone with a secure lock the **OS keyguard** sits above `LockActivity` and
  above anything `am start` launches: the dialer never reaches the front and the row reported
  `LockActivity` on top whether or not the overlay exempts the dialer. The probe now tries
  `wm dismiss-keyguard` + a swipe, and if the keyguard survives it records **NOT MEASURED** and exits
  non-zero instead of FAIL (`RecordNote`; `docs/TESTING.md` §5f). A `NOT MEASURED` row is not green —
  the run fails, because a hidden precondition that silently flips a verdict is how a gate stops being
  one. Consequence for the record: the *original* S1 FAIL on `main` was measured on a phone without a
  secure lock, so it stands; but it can no longer be reproduced on a locked handset without unlocking
  it first, and the probe says so instead of guessing.
- **Second cause, and the dominant one: the overlay re-raised *itself*.** With the keyguard down and the
  exemption in place, S1 still read `LockActivity` on top at 2 s, 6 s and 11 s (`cec3f82`, Flip4,
  2026-10-17). The control run with the overlay down showed the dialer's task had been created and then
  never resumed — so the dialer was launched and the overlay took the front back. `LockActivity.onPause()`
  and `onUserLeaveHint()` started the activity again unconditionally; `onPause` fires on the way out,
  before the next window is known, so it also fired for the emergency dialer. `shouldReraise` was already
  returning `false`, and the service never re-raised: the activity did it to itself. The self-re-raise is
  removed; re-raising is now only `AccessibilityMonitorService`'s job for non-exempt foreground windows
  (documented in the class: with the accessibility service off there is no self-re-raise, and that
  service is already a hard requirement for blocking and the tamper guard). JVM suites unchanged:
  33 suites / 219 tests / 0 failures.
- **The overlay no longer draws over the OS keyguard (issue #87, found as an owner lockout).** `LockActivity`
  drew over the keyguard twice — the window flag in `onCreate` **and** `android:showWhenLocked="true"` in
  the manifest — and a `pause` sent while the bouncer was up put the overlay *in front of* the PIN pad: the owner could not unlock their own phone and the only recovery was `resume` from the
  server. The flag is gone and `KeyguardPolicy.shouldDeferToKeyguard(mode, keyguardLocked)` makes every
  locking mode (`locked`, `paused`, `paused_internet`, and the default) finish instead of drawing while a
  keyguard is up; `unlock` and `dismiss` still run because they *end* the lock. Nothing is lost from the
  parent's side — `LockState` keeps the mode and the accessibility service re-raises the overlay over the
  first non-exempt window after the keyguard goes. Trade recorded here on purpose: a child waking a locked
  phone now sees the keyguard first instead of the parent's message; the same asymmetry as the emergency
  dialer applies (an owner locked out of their own device costs more than one screen of messaging).
  Tests: four JVM cases, including a check that pins the policy's mode names to `LockActivity`'s constants
  so the rule cannot silently invert; 34 suites / 223 tests / 0 failures. Measured on the Flip4 with the
  keyguard up: `lock` and `pause` delivered, **neither overlay appeared** (`0` activity records for
  `LockActivity`/`BlockActivity`), the keyguard stayed up.
- **The same defect was in the app-block screen, found by the S2 run itself.** `BlockActivity` carried the
  same manifest attribute and window flag; on the handset, with the keyguard up, it was the block overlay
  that stayed in front (the new `LockActivity` correctly never appeared). It now applies the same
  `KeyguardPolicy` rule and drops `showWhenLocked`; a block screen has nothing to do while the phone is
  locked, and covering the bouncer only hides the owner's PIN pad. `RingActivity` keeps `showWhenLocked`
  on purpose — a parent-triggered ring must be visible while locked, and it is dismissible with the PIN.
- **The gate now has a row for the opposite failure (issue #87).** `S2` sends `lock` (a real keyguard),
  then `pause`, and requires `dumpsys window | grep mCurrentFocus` **not** to be `LockActivity`: the owner
  must always be able to reach their own PIN. It fails on the 2026-10-17 builds — a `pause` over a live
  bouncer put the overlay in front and the only recovery was `resume` from the server — and it is a safety
  row, so a `NOT MEASURED` or a FAIL exits the run non-zero. `docs/TESTING.md` §5f carries the reasoning
  (focus from the window manager, not the activity stack).
- **Not fixed here:** #81 (`pm clear` wipes the agent despite active admin) — separate, high, and
  mitigated by `device_silent` plus parent-minted pairing. **Correction 2026-10-18:** the
  `device_silent` half did not fire as merged — the job matched a status no writer produces (audit
  finding 4, fixed in the Unreleased entry above). Until that fix, `pm clear` was detected only by
  the parent noticing the device had gone quiet.
### Process — the one physical test phone is leased, one agent at a time (`AGENTS.md` §9)
- Why: on 2026-10-17 a parental `lock` was left applied on the Galaxy Z Flip4 (`R5CW116Y6GF`) while the
  agent that sent it went unreachable. The phone sat behind the overlay and the Phase 1 gate (`TR-15`,
  the ten-bypass probe) needed the handset. The rule that replaces "ask whoever had it" does not depend
  on the previous owner answering (`AGENTS.md:191`).
- `AGENTS.md` §9.1–9.5: the device warden (Kimi Code, programme lead from 2026-10-17) is the arbiter, but
  the routine mechanism is a **lease held through `scripts/hardware/phone-claim.ps1`** — one claim per
  serial, **60 minutes by default, hard ceiling 240** (`-Minutes` is rejected outside 5..240), renewed
  with `Heartbeat`, and **expiring on its own** so ownership returns to the pool without the previous
  owner's consent. The board line in `docs/QA/TEST-REQUESTS.md` is a *mirror* of the lease for humans,
  not a second lock: a manual "GRANTED" step was rejected because it reintroduces the unreachable-warden
  failure this rule exists to remove. A restriction (`lock`, `pause`, `pause_internet`, ring) is a test
  action, never a reservation; release clears and verifies it and ends with
  `DEVICE R5CW116Y6GF — released <time> UTC — clean`. A run without a live lease, or one that collides
  with another agent's, is not evidence and may be required again (`AGENTS.md:283`).
- `docs/QA/DEVICE-REGISTER.md`: the durable register for the handset — its identity, the state a run
  leaves behind, the per-run checklist, the locked-phone recovery order, and an append-only decision log.
  It defers to §9 and the script rather than restating a second protocol.
- `docs/TESTING.md` §5.0 (`docs/TESTING.md:109`): pre-flight before the first `adb` — keyguard state,
  no `LockActivity`, `adb reverse --list`, live agent pid, and **queued** restrictions via
  `GET /v1/devices/:id/commands/history` (the queue is durable; a `lock` sent near the end of a lease
  can land on the next owner). Takeover of an expired lease applies `unlock` (safe-direction) and waits
  up to 90 s; if the keyguard is showing it stops and waits for the human. `am force-stop` is the last
  resort and leaves the agent in the stopped state (probe row 3, §5f).
- `scripts/hardware/phone-claim.ps1`: `Claim` / `Heartbeat` / `Release` / `Status` / `Wait` / `Break`.
  The store is `%LOCALAPPDATA%\OSRA\phone-claims` (or `OSRA_PHONE_CLAIM_STORE`), outside every checkout
  so one claim is visible to every clone and does not appear in `git status`. `FileMode.CreateNew`
  decides the claim race, and an expired claim is renamed aside and re-read before takeover, so two
  takers cannot delete each other's fresh claim. `-LeftState Clean|Locked|Unknown` is mandatory on
  release; `Locked` prints the recovery step and is journalled. The helper never calls `adb`: it records
  permission, not hygiene, and is coordination rather than access control — a remote agent that does not
  read the board is still governed by the board (`scripts/hardware/phone-claim.ps1:10`).
- **Not verified here**: this entry describes the rule, the procedure and the helper; no hardware run was
  performed for it (the handset was in use by the 11-row probe). The script parses cleanly under Windows
  PowerShell 5.1 (`Parser::ParseFile`), but its claim/expiry races were not exercised, and the takeover
  sequence has not been re-run. The first live use is the verification.

### Android + API — durable on-device scan queue (plan 2.6, first half)
- `SocialScanQueue` writes every capture to Room (`pending_scans`; migration 2→3 keeps existing rows)
  before sending, so a process kill, a reboot or an offline stretch loses nothing. Rows go oldest-first
  in batches of 50, are deleted on 2xx, counted down on failure and dropped after 8 attempts or 48 h
  (`ScanQueuePolicy`, tested). `ScanFlushWorker` retries under a network constraint with backoff and
  sweeps every 15 min. `SocialScanDto`/the API's `ScanSchema` carry an optional `source`.
- The notification-side capture (the second half of 2.6) follows in its own PR.

### API — device-silence watch (a plan-1.9 probe finding)
- The probe's bypass #2 showed that `pm clear` wipes the agent's pairing with Device Admin active and
  no client-side alert is possible afterwards. `src/jobs/deviceSilence.ts`: every 5 min, an `online`
  device unseen for `DEVICE_SILENT_MINUTES` (default 30) gets one critical `tamper` /
  `device_silent` alert (Redis claim per episode, no duplicates across instances) and is set
  `offline`; the next telemetry sets it back to `online`. Tests: `device-silence.test.ts`.
- **Corrected 2026-10-18 (audit finding 4):** the job as merged above matched `"active"`, which no
  writer produces, so it never fired; the wording here described the intent, not the code. The watch
  now matches `online` and has a route-to-job regression test — see the Unreleased entry.

### Android — adversarial bypass probe (plan 1.9, the Phase 1 gate)
- `scripts/hardware/android-bypass-probe.ps1`: an `adb`-driven run of the ten bypasses a child tries
  on a paired phone — `adb uninstall`, `pm clear`, force-stop, accessibility off, overlay revoked,
  Private DNS provider, escaping the lock (Home / Recents / Settings), going offline to dodge or
  escape a lock, disconnecting the web-filter VPN, deactivating device admin — each a measured
  outcome (blocked, or the tamper alert's latency from Postgres) and a PASS/FAIL table for the PR.
- Two gaps it found while being written are closed in the agent: a Private DNS provider set outside
  the guarded dialog and a revoked overlay permission now raise `tamper` alerts
  (`private_dns_bypass`, `overlay_revoked`) from the 60-s loop.

### Android — release hardening (plan 1.8)
- `targetSdk 35` / `compileSdk 35` (Play's 2025 bar); `versionName 0.2.0`.
- Release build is **minified and resource-shrunk** (R8, `proguard-rules.pro` keeps Moshi DTOs,
  Retrofit, Room, Hilt entry points and OS-instantiated components) and **HTTPS-only**
  (`src/main/res/xml/network_security_config.xml` → `cleartextTrafficPermitted="false"`); the debug
  build keeps cleartext for LAN / `adb reverse` dev servers through `src/debug/res/xml/`.
- Release signing from the same upload keystore as the parent app (`OSRA_UPLOAD_KEYSTORE`,
  `_KEYSTORE_PASSWORD`, `_KEY_ALIAS`, `_KEY_PASSWORD`; CI materialises it from
  `OSRA_UPLOAD_KEYSTORE_B64`), debug key with a warning when absent.
- The **device JWT and the per-device HMAC secret moved into the keystore-backed encrypted store**
  (`SecureStore`), migrated from plaintext DataStore on first read — the audit finding ADR-0010 left
  for "a follow-up".
- CI asserts `targetSdkVersion:'35'` on the release APK and the cleartext settings of both configs.

### Android + API — ring that cannot be silenced, locate with a fresh fix (plan 1.7)
- `commands/Ringer` + `RingActivity`: the ring forces the **alarm stream to its maximum** (restored
  afterwards unless someone changed it), plays on `USAGE_ALARM` (through Do-Not-Disturb), holds a
  screen-on wake lock, shows a full-screen red "Your parent is ringing this phone" over the lock
  screen, swallows Back and the volume keys, and stops only on the **parent PIN** (tamper guard,
  reason `ring`), a parent `stop_ring` / `sos_clear`, or the 5-minute cap (`RingPolicy`, tested).
- `locate_now` now asks the fused provider for a **fresh high-accuracy fix** with a 30-s timeout and
  flushes it at once; the cached fix is used only when fresh fails and it is < 5 min old
  (`LocatePolicy`, tested). Before: `lastLocation` only — whatever the OS had, however old.
- API: `locate_now` and `stop_ring` accepted by `POST /v1/devices/:id/command` (`stop_ring` is
  safe-direction, so it works with consent revoked); TTL 10 min like `ring`. Tests extended.

### Android — guided, verified onboarding (plan 1.6)
- `setup/OnboardingPolicy` (pure) + `setup/GrantChecks`: nine grants — accessibility, usage access,
  display over other apps, device admin, web-filter consent, location (foreground + background),
  Private DNS not on a provider (required); battery exemption, notification access (recommended).
  Each is asked of the OS on every render; each row has its reason, the OEM hint (Samsung / Xiaomi /
  Huawei / ColorOS) and a button that opens exactly the screen that grants it.
- **"Setup complete" is reachable only when every required grant is in**; otherwise the checklist is
  the screen, and the status screen says "`n` of 7 required grants done" with a *Finish protection*
  button. Background location is asked as the second OS prompt it is on Android 10+.
- The Private DNS provider dialog is now a protection screen for the accessibility guard (PIN gate)
  while the web filter is enabled — a named provider would bypass the sinkhole.
- Tests: `OnboardingPolicyTest` (5), `TamperScreenPolicyTest` +1.

### Android — web filter on the phone: local DNS sinkhole (ADR-0015, plan 1.4)
- New `vpn/FilterVpnService`: a `VpnService` that routes **only its own resolver** (`10.111.222.2`)
  into the tunnel, so every app's DNS is decided by the agent and no payload traffic is proxied.
  `DnsFilterPolicy` (pure, 10 tests) decides pause > allowed > SafeSearch / YouTube rewrite > blocked
  domain > blocked category > forward; sunk names answer `0.0.0.0`/`::`; SafeSearch and YouTube
  Restricted are CNAME rewrites to the engines' enforcement hosts with real upstream addresses.
- `pause_internet` now takes the default route and drops everything except the agent and the parent's
  always-allowed apps (`addDisallowedApplication`); `resume_internet` returns to DNS-only.
- Blocked categories now also carry their **domains** from the blocklist pack
  (`BlocklistStore.mergeDomains`, persisted); `youtubeRestrictedMode` added to the Android rule DTO.
- Onboarding + status screen: "Set up web filter" (the one-time OS VPN consent) / connected /
  "Reconnect web filter"; the boot receiver restarts the tunnel; rules sync reloads the table.
- VPN revoked (another VPN app, or disconnected in Settings) → `tamper` alert
  `content_filter_disconnected`; the `vpn_detected` check stands down while our own tunnel is up.
- Manifest: `FOREGROUND_SERVICE_SPECIAL_USE`, service type `specialUse` with the Play subtype text.
- Tests: `DnsFilterPolicyTest`, `DnsMessageTest`, `IpPacketTest` (RFC 1035 / IPv4+IPv6 UDP codecs).
- Docs: ADR-0015, TESTING §5c (hardware procedure), README feature line, ROADMAP 1.4.
### Process — role split, release runbook, and work-state labels (`AGENTS.md` §1, §2, §6.5, §10; `docs/RELEASING.md`)
- **The maintainer re-cut the roles on 2026-10-17.** `AGENTS.md` §1 now reads: **Kimi Code** is the
  development lead — implements, **owns `main`** (the only merging agent) and **owns releases**; **Claude
  (KCL lead)** owns architecture and constructive testing support (ADRs, design review, tests,
  checklists); **Antigravity** is the testing lane (gates, falsifiable claims, hardware rows, `TR-*`
  results); the **human maintainer** holds every account, purchase, entitlement and the final scope call.
  The old table said Kimi "must not ship product fixes", which by afternoon described the opposite of
  the job.
- The principle the old document was built on is unchanged and re-expressed: **the author of a change is
  never its only verifier.** §6.5 now makes that operational — the lead may merge, but not work
  (including their own) that another lane has not verified, and the merge message must cite the
  verifier, the `TR-*` row, the sha and the numbers.
- **New `docs/RELEASING.md`** — the runbook for the responsibility that came with the role: entry
  criteria (E1–E6), the nine release steps (freeze → version and changelog → clean build → prove the
  artifacts → release record → merge with its verification line → tag → distribute → close), key custody,
  withdrawal/rollback, hotfix, thirteen traps, and a copy-paste checklist. It is written for the fact
  that every artifact claim must rest on a gate run by another lane.
- **New `AGENTS.md` §10 — work-state labels**, so nobody tests a half-finished tree or interrupts a run:
  `state:wip` (the default for a draft PR), `state:ready-for-verification`, `state:verifying`,
  `state:verified`, `state:changes-requested`, `state:needs-arch`, `state:blocked`. Read from a single
  API call; a draft PR is WIP regardless of labels; a head commit younger than 10 minutes is treated as
  in flux; silence is not readiness; and a label never grants the phone (that is the lease, §9).
- **Cadence shortened deliberately, twice, and agreed with Claude's #84 rather than beside it:** the board
  heartbeat is **every 15 minutes while a request is open** (30 minutes when nothing is open), one line
  per agent in the host mailbox `status/`, and each pass is one API call unless something is labelled
  ready. The labels — not the heartbeat — are the signal that a tree is testable: `state:wip` forbids
  testing, reviewing and merging; `state:ready-for-verification` invites it. A head commit younger than
  10 minutes is treated as in flux. The point of the labels is that the cheap check is also the accurate
  one. **The floor is Claude's, not mine:** its scheduler allows a 60-minute check, so every OSRA ask
  carries a default that proceeds at 60 minutes of silence; a shorter heartbeat on this side must never
  turn into a blocked lane.
- **Not verified here**: the role text and the runbook describe intent, not behaviour. The label
  protocol is exercised by this PR itself (it carries `state:ready-for-verification`), and the release
  steps have not been run end to end because no release is being cut.
### QA — WO-04: the branch-prune list for plan 0.5 (`docs/QA/BRANCH-PRUNE-2026-10-17.md`)
- Every remote branch with the PR that carried it and whether its tip is an ancestor of `main`: **40 merged**
  (39 with a PR, `ANTIGRAVITY` predating the workflow) and **3 not merged**. Recommendation: delete the 40,
  keep `KCL` (plan provenance), `feat/android-dns-sinkhole` (open PR #78) and treat
  `qa/verify-track12-2026-10-12` as a superseded second copy of a log entry `main` already has
  (`DISCUSSION-LOG.md:978`).
- **Nothing was deleted.** Plan 0.5 needs the maintainer's go, and the document exists so that go can be given
  against a table instead of a guess; the delete command is one copy-paste block inside it.
- Also in this PR: the trap row for the failure I hit today — a background build that reports a *plausible but
  wrong* count after the working tree changed under it (`docs/TESTING.md` §6), with the sha check that catches it.


### Android — tamper protection wired: parent PIN at pairing, Device Admin, PIN gate over the OS removal screens (ADR-0010, plan 1.1/1.2)
- **Pairing now ends with the parent setting a PIN** (4–8 digits, weak ones refused; PBKDF2 hash in
  `EncryptedSharedPreferences`) and activating **Device Admin** (`FamilyShieldDeviceAdmin`, policies
  `force-lock` + `watch-login`). The status screen shows the protection tier (owner / admin /
  alert-only) and offers activation when it is missing.
- **No child-side path clears pairing any more:** Re-pair and the new Remove-protection button open the
  PIN gate (`TamperGuardActivity`) first; five wrong PINs or Back go to the launcher.
- **The accessibility service guards the three OS screens** that strip protection — Settings ›
  deactivate device admin, the package installer's uninstall dialog, App info for this package
  (`TamperScreenPolicy`, pure + JVM-tested for AOSP/Google/Samsung wording). It presses Back, raises
  the PIN gate and sends the parent a `tamper` alert (`protection_screen_opened`). A verified PIN
  grants a 2-minute grace window.
- **Admin removal reaches the parent within seconds:** `onDisabled` enqueues an expedited
  `TamperAlertWorker` (`device_admin_removed`); the 60-s loop in `LocationService` is the backstop and
  also alerts on a tier drop. A removal done by the parent through the app (PIN) is sanctioned and silent.
- `lock` now calls `DevicePolicyManager.lockNow()` on admin/owner and still shows the overlay.
- **Lock that holds (plan 1.3):** the lock/pause mode is persisted (`LockState`); the accessibility
  service re-raises the overlay over any other window while it is active (phone calls, emergency dialer
  and the system UI excepted — `LockEnforcementPolicy`, JVM-tested); `BootReceiver` re-applies it after
  a restart; onboarding and the status screen ask for "display over other apps" explicitly.
- Tests: `ParentPinTest`, `TamperPolicyTest`, `TamperScreenPolicyTest` (JVM). Hardware acceptance per
  `docs/TESTING.md` §5a — ⚠️ recorded on the board as **TR-10** when run; not claimed here until then.

### Security — legacy v1 agent signatures are now refused by default (`INTERNAL_SIGNING_ALLOW_V1` opt-in)
- `allowLegacyV1()` returns true only for `INTERNAL_SIGNING_ALLOW_V1=1` (was: anything but `0`). Body-only
  signatures from a per-device secret get `401 legacy_signature_disabled` unless an operator opts in for a
  rollout whose agents still sign v1; the probe then reports **J7** as a target, so the state is visible.
  Promised in ADR-0014 "after hardware verification of the agents": TR-07's hardware half verified the
  Android v2 signer on a Galaxy Z Flip4 (Android 16) on 2026-10-17 (alert 201 with v1 on and off); the
  Windows and iOS signers are verified by their unit tests against the shared reference vector.
- Three unit tests that still signed v1 (`content.test.ts` ×2, `token-hygiene.test.ts`) now sign v2 — they
  failed on the new default, which is the fails-before evidence for the flip. `internal-signing.test.ts`
  asserts: refused with the variable unset, refused with `0`, accepted with `1`.
- Docs: `docs/TESTING.md` env table, `README.md` limitations (J7 is a gating check now), `docs/SPEC.md`,
  `.env.example` (`=0`), ADR-0014 follow-up note.
- **Gates here** (zero-migrated `Asia/Dubai` DB, API `:3019`, default env): vitest **296/296**, `tsc`
  clean, probe **109 passed · 0 failed · 0 targets · 0 notes** (J7 PASS), e2e **69/69**.
- New `scripts/hardware/android-signing-tr07.ps1`: the TR-07 hardware half as a script for the Windows
  test host (pairs the phone through the real launcher via `uiautomator`, fires SOS through the
  quick-settings tile, checks the API log + DB, cleans up per AGENTS.md §7). Seed of plan item 1.9.

### Android — SOS quick-settings tile did nothing on Android 14+ (found in TR-07 on hardware)
- `SosTileService.onClick` used `TileService.startActivityAndCollapse(Intent)`, which Android 14 (API 34)
  removed: the system delivered the tap (`TileLifecycleManager: onClick … SosTileService` in logcat) and
  the SOS screen never opened — on every current phone, the child's SOS button was dead. Found on a
  Galaxy Z Flip4 / Android 16 while running the TR-07 hardware half; the unit suite could not see it.
- Fix: API 34+ hands the system a `PendingIntent` (`FLAG_IMMUTABLE | FLAG_UPDATE_CURRENT`); API 26–33
  keep the Intent overload. Verified on the Flip4: tile tap → `SosActivity` → SOS → `POST
  /v1/alerts/internal` 201 (the TR-07 evidence). Not unit-tested — `TileService` behaviour is a
  platform contract; the hardware run is the test and is recorded on the board.

### QA — environment trap: the shared `:3000` API must not be hosted inside an agent task manager (issue #71)
- Twice today the shared test API died with **no crash trace** — its log's last lines were normal `200`s — and both times the death coincided with an agent stopping a *different* background task. The likely mechanism is that the task runner kills a **process group**, and the shared server was started inside one.
- Impact is not data loss but diagnosis: `qa-probe` / `e2e` then fail with **connection refused**, which reads like a product or network bug, and a second tester racing to restart it produces a confusing `EADDRINUSE` while the environment is actually fine.
- Recorded as a trap row in `docs/TESTING.md` §6 with the rule (start it detached; if it is down, say so on the board rather than starting a competing instance) and the detection cue (a clean log end means killed, not crashed). Full evidence and the open ownership question are in issue #71.

### CI — `probe-integrity` job (follow-up to #68)
- `scripts/check-probe-integrity.mjs` now runs on every pull request (`.github/workflows/ci.yml`, job
  `probe-integrity`, `--base origin/<base> --head HEAD`): a removed or demoted probe assertion fails
  the PR unless `scripts/probe-gate-acks.json` acknowledges it. Verified: `main → fix/security-targets`
  exit 0 with the four TR-07 acks, exit 1 without; a scratch demotion of `M2` to a note → exit 1.

### QA — the "gates may only be extended" rule is now machine-checked (`scripts/check-probe-integrity.mjs`)
- **Why:** `AGENTS.md` §4 forbids weakening a check, but the rule depended on a tester reading a diff by
  eye — and these diffs are large (PR #65 changed `qa-probe.mjs` by **225 added / 43 deleted**). A
  deleted or renamed assertion is the change that looks innocuous in a stat line.
- **What:** `scripts/check-probe-integrity.mjs` compares the assertion-name sets per severity between two
  revisions and **exits 1 on a removal or demotion** (`check` → `target`/`note`); additions and
  promotions (`target` → `check`) are reported as information. A legitimate rename must be recorded in
  `scripts/probe-gate-acks.json` with a reason, so nothing disappears without a written justification.
- **Verified:** on `main → fix/security-targets` it flags exactly the four changes Kimi verified by hand
  in TR-07 (two renames with stronger conditions, one closed target, one retired note) and exits **1**
  without the acknowledgements, **0** with them; on `main → feat/backend-usage-model@b6ea5b4` (a clean
  extension) it reports **11 added, 0 removed** and exits 0.
- **Honest limits, documented in both the script and `docs/TESTING.md`:** loop-generated names collapse
  into one comparable entry per assertion family, and dynamically built names cannot be compared (they
  are counted and reported). This narrows a reviewer's search; it does not replace the reviewer.

### Security — Phase 2d: signing v2 (J2/J6 closed), revocable sessions, co-parent roles, MFA secret at rest (ADR-0014, closes #42, #44)
- **Internal signing v2** (`src/lib/internalAuth.ts`): `X-FamilyShield-Timestamp` + `X-FamilyShield-Nonce` +
  HMAC over `"<ts>.<nonce>.<body>"`; ±300 s skew window, per-signer nonce window (Redis `SET NX`), and a
  `reason` code on every 401 (`replay`, `stale_timestamp`, `missing_nonce`, `legacy_signature_disabled`,
  `global_secret_requires_service_caller`, `device_has_no_secret`). The global secret is a **service
  credential**: v2 + `X-FamilyShield-Caller` ∈ `INTERNAL_SERVICE_CALLERS` (default `ai-engine`), never
  bare. **J2 and J6 are now gating probe checks**; the E4 note is gone. Legacy body-only (v1) device
  signatures stay accepted while `INTERNAL_SIGNING_ALLOW_V1` ≠ 0 (new target **J7** reports it).
- **All three agents sign v2:** Android `SignatureInterceptor` (timestamp/nonce headers, `signingBytes`),
  Windows `Services/InternalSigner.cs` used by `ApiClient.PostAlert`, iOS `InternalSigner.swift` used by
  `AlertReporter`. Each has a unit test pinned to the **same reference vector** as the API test
  (`ce725cf9…c220508`). ⚠️ Agent suites not run here (no SDK/.NET/Xcode in the sandbox) — CI runs the
  Android and .NET ones; hardware verification is TR-07.
- **Parent sessions** (`src/lib/sessions.ts`): `jti` + `familyRole` on every token (login, register,
  refresh, invite accept); `auth:invalid-before:<parentId>` bumped by password reset / MFA enable /
  logout-all / theft, so live access tokens die immediately (`401 session_revoked`); `/logout` with a
  refresh token also revokes its access token; rotation keeps the old-hash → new-jti link so reuse of
  a consumed refresh token still kills the session it rotated into (F3).
- **Family roles**: invite acceptance mints `role: "parent"` + `familyRole` (co-parents were locked out
  by `requireParent` before); `requireOwner` on child create/erase, consent grant/revoke, invites;
  `requirePermission` on rules writes + controls (`rules`), alert ack (`alerts`), device command/unpair
  (`devices`), geofences (`location`). Reads are never gated. `PERMISSIONS` exported from the middleware.
- **MFA secret encrypted at rest** (`src/lib/secretVault.ts`, `enc1:` prefix under `VAULT_KEY`); legacy
  plaintext rows verify and are re-encrypted at next login. `VAULT_KEY` is required in production.
- **Gates:** e2e **68/68** (+2: replay → 401 `replay`; 10-min-old timestamp → 401; the device/global
  isolation check now also proves bare global fails). Probe **108 passed · 0 failed · 1 target (J7) ·
  0 notes**: E4/J2, E4b, E4c, J5 (v1 and v2-no-caller), J6, J6b, F8, **N1–N7** (jti/familyRole,
  logout-all kills the live token, single logout kills its token, invite → working co-parent token,
  permission 403s, owner-only erasure, granted permission works). New unit suites
  `internal-signing.test.ts` (7) and `sessions-and-roles.test.ts` (7); **14 fail on `main`**.
  vitest **295/295**.
- **#66 (Kimi, TR-06 verification):** `/v1/family/me` preferred the Redis counter whenever the key
  existed, so a flush was survived only until the next telemetry delta recreated the counter from
  that delta alone (5 instead of 19). Now the larger of the cache and the durable day total wins —
  deltas are monotonic within a day, so that is right in both directions (a failed rollup write
  leaves the cache ahead). Unit test (fails before) + e2e check (`+5` after the flush → 35, not 5).
- **Verified here** on a zero-migrated `Asia/Dubai` database, API `:3019`: e2e **69/69** after the
  #66 fix. ⚠️ Not verified on the testers' hosts or hardware yet — **TR-07**.

### Backend — Phase 2c: durable usage model, retention, complete erasure cascade (ADR-0013)
- **New tables** (migration `0013_usage_model`): `AppUsageDaily` (child × device × UTC day × app →
  minutes; `app="*"` is the device-reported day total) and `WebVisit` (one row per URL event). Written
  incrementally by `POST /devices/:id/activity` and `/telemetry`; reconciled nightly from
  `ActivityEvent` by `src/jobs/usageRollup.ts` (overwrite, idempotent; `ROLLUP_HOUR_UTC`, default 02:00,
  Redis `SET NX` claim, `JOBS_ENABLED=0` for an external cron). A rollup write failure never rejects a
  batch.
- **Reads no longer depend on Redis:** `/v1/family/me` falls back to the durable day total when the
  `usage:child:*` key is gone; new `GET /v1/reports/usage?childId&days` (per-day series + per-app split,
  the data for trend charts) and `GET /v1/reports/web?childId&days&limit&blocked&domain` (browsing
  history) — family-scoped, bounds validated (400).
- **Retention:** raw `ActivityEvent`/`WebVisit`/`SocialEvent`/`LocationPing` deleted after
  `RETENTION_DAYS` (90, floor 7), rollups after `ROLLUP_RETENTION_DAYS` (365); instants bound from JS.
- **Erasure (`DELETE /v1/family/children/:id`) now covers every child-scoped table** — it previously
  left `ActivityEvent`, `SocialEvent`, `InstallRequest` and `DeviceCommand` rows orphaned — in one
  transaction (`eraseChildData()`, list pinned by a test), returns `deletedDevices` + per-table `rows`,
  revokes each deleted device's JWT like an unpair (#56 TTL) and drops the child's Redis keys.
  `DEVICE_TOKEN_TTL_SECONDS` moved to `src/lib/deviceToken.ts` (re-exported from `devices.ts`).
- **Gates:** e2e gains 9 checks (rollup survives `DEL usage:child:*`; `/reports/usage` 21/9 with the
  live heartbeat excluded; `/reports/web` + `blocked=true`; erasure counts; erased device → 401; and,
  when the gate shell has `DATABASE_URL`, **a Postgres count of 0 rows in all 13 tables**). Probe
  gains **M1–M6** (bounds; cross-family erasure 403 with the child intact; own erasure counts;
  erased device 401 on commands *and* ping; 404 afterwards) and `B5b`; `B5` now hits the real route.
  New unit suite `test/usage-model.test.ts` (13 tests); the cascade test in `test/family.test.ts` now
  asserts 13 deletes and the revocation writes.
- **Verified here** (DB from zero, `Asia/Dubai`, API `:3019`): vitest **281/281** (24 files), `tsc`
  clean, e2e **66 passed, 0 failed**, probe **95 passed · 0 failed · 2 targets · 1 note**; rollup run
  twice on seeded rows overwrote a stale 999 → 17 and reaped a 107-day-old event, second run identical
  (rows then removed — hygiene rule §7). ⚠️ Not verified on the testers' hosts yet — **TR-06**.

### Backend — TR-05: WebSocket `ready` frame; Redis state bounded (#56, #57)
- **Realtime contract (product change, decided under TR-04):** the gateway now sends
  `{type:"ready", familyId, ts}` as the **first frame on every socket**, immediately after it adds the
  socket to the family set (`src/realtime/gateway.ts`). A client that has not seen `ready` cannot know
  whether a published event reached it; one that has can treat a missing event as a delivery failure
  rather than a race. `docs/SPEC.md` and `README.md` record the contract.
- **Gates:** `scripts/e2e.mjs` §7 waits for `ready` before posting the alert and no longer polls the
  Redis ticket key (one mechanism, not two — Kimi's question on #62); a new check asserts `ready` is the
  first frame and names the family. `scripts/qa-probe.mjs` gains **L1–L5** (ready first and bound to
  the caller's family; an alert published after ready arrives after it; no event precedes ready;
  invalid ticket → `4001` with no ready; a consumed ticket cannot open a second socket). The probe now
  carries the same `--experimental-websocket` re-exec shim as e2e for Node 20. New unit suite
  `test/realtime.test.ts` opens real sockets against a listening Fastify instance (3 tests; 2 of them
  fail on the previous gateway).
- **#56 — `revoked:device:<id>` is bounded, not reaped.** Unpair now writes it with `EX` =
  `DEVICE_TOKEN_TTL_SECONDS` (10 y = 315 576 000 s), the same constant the device JWT is minted with
  (`expiresIn` was the `ms` string `"10y"`, now the number — identical lifetime, and a test proves
  `exp − iat` equals the key's TTL so the two cannot drift). The handler comment states that the key is
  security state and must never be shortened or deleted while the token could still be presented;
  `scripts/cleanup-test-redis.mjs` already keeps it. Keys written before this change keep `TTL -1`
  until the next unpair of that id (the QA tool reports them; they are still controls).
- **#57 — `refresh:index:<parentId>` no longer leaks.** `/logout` reads the owner from the live record
  *before* deleting it and `srem`s the hash; the expired-but-present path does the same; both go through
  one `retireRefreshToken()` helper shared with rotation. The index SET re-arms a 30-day TTL on every
  issue (`expire`), so an abandoned index disappears a refresh-lifetime after the last login even if a
  path is ever missed. Four new tests in `test/token-hygiene.test.ts` (logout removes only that
  session's hash; expired token is retired from the index; TTL re-armed; #56 bound) — all four fail on
  the previous code.
- **Verified here** on a database created from zero with session zone `Asia/Dubai`, API on `:3019`:
  vitest **268/268** (23 files), `tsc` clean, **e2e 57 passed, 0 failed** (56 + the ready check),
  **qa-probe 88 passed · 0 failed · 2 targets (J2, J6) · 1 note (E4)** (83 + L1–L5). Live Redis:
  the logged-out session's hash is absent from its `refresh:index:*` set; a fresh unpair's
  `revoked:device:*` key reports `TTL 315576000`. ⚠️ Not verified on the testers' hosts yet — that is
  **TR-05**.

### QA — TR-03 (post-merge smoke of `main`) and TR-04 (e2e WebSocket harness), in the same PR as TR-01/TR-02
- **TR-03 — `main`@`e1e0f74` smoked on a database created from zero**, session zone `Asia/Dubai`:
  `prisma migrate deploy` applied **all 12 migrations** to an empty database (0001→0012, including the
  `0012_device_command_timestamptz` upgrade clause), `prisma generate` + `tsc` clean, `seed.ts` seeded,
  API started on `:3018` with no schema-drift warning. Gates on that stack: **qa-probe 83 passed ·
  0 failed · 2 targets (J2, J6) · 1 note (E4)** and **e2e 56 passed, 0 failed** — the same numbers as
  the branches, now on `main` itself. Client suites: **`flutter test` (parent-app) 103/103**;
  Android `./gradlew testDebugUnitTest` result recorded in `docs/QA/DISCUSSION-LOG.md`.
- **TR-04 — the e2e WebSocket harness is hardened, without loosening the check.** `scripts/e2e.mjs` §7
  no longer arms a one-shot promise: it collects frames, waits for the single-use ticket to be consumed
  before posting the alert, re-posts the stimulus up to 3× if no frame arrives, and reports `frames=`,
  `wsError=` and `wsClose=` on failure. The assertion is unchanged — the alert must be delivered.
  **Acceptance met: e2e 56/56 on four consecutive runs, no `ws timeout` abort.**
- **Correction, and it matters:** the TR-01 explanation I gave for that abort — "the frame is published
  before the server registers the socket" — **does not reproduce**. Immediate-post trials delivered
  **20/20**, and `main`'s unmodified harness also passed the exact original sequence (probe load, 70 s,
  e2e). So the abort was a one-off whose cause is still unidentified; the harness fix is defensive and
  the diagnostics exist so the next occurrence can be explained. `docs/TESTING.md` states this rather
  than the retracted hypothesis.
- **Verified:** all numbers above reproduced on the host PC; the smoke database was dropped afterwards.

### Fixed — Issue #53 (critical, found by Kimi + Antigravity verification of PR #52): command queue dead on non-UTC databases
- `DeviceCommand` time columns were `TIMESTAMP(3)` (no time zone) while the queue's raw SQL compared them to `NOW()` (timestamptz). On any database session outside UTC (the testers' Asia/Dubai hosts) the naive UTC value was read as local wall-clock, so every fresh command was swept to `expired` before the device could drain it — ring/lock/unlock never arrived. The author's UTC stack hid it (e2e 56/56 there, 53/56 in Dubai).
- Fix: migration `0012_device_command_timestamptz` converts the four columns to `TIMESTAMPTZ(3)` (`USING … AT TIME ZONE 'UTC'`), and `deviceCommands.ts` binds the instant from JS — there is no `NOW()` left in the module (a unit test now scans the source and the generated SQL for it).
- Gate coverage: `qa-probe` gains **K1–K4** (device drains a fresh command, history says delivered, ack flips to acked, acked is not re-offered) — the probe previously never asserted a device receives anything. `docs/TESTING.md` now requires the live gates to run against a non-UTC database (`ALTER DATABASE … SET timezone = 'Asia/Dubai'`).
- Verified on a lane-2 database set to Asia/Dubai: before the fix e2e **53/56** (the testers' exact three failures); after: e2e **56/56** twice, `qa-probe` **83 passed · 0 failed**, vitest **261/261**.

### Added — Phase 2b: commands are durable and observable — KCL plan, ADR-0012
- **`DeviceCommand` table** (migration `0011_device_command_queue`): every command is a row with `pending → delivered → acked | failed`, or `expired`; `requestedBy`, `attempts`, `result`. The Redis list is gone; pub/sub remains the wake-up only. A Redis restart no longer loses a pending lock.
- **Per-type expiry**: `ring`/`locate_now` 10 min, `rules_updated` 24 h, consent commands 7 d, default 24 h. `rules_updated` coalesces onto an existing pending row.
- **Atomic drain** (`UPDATE … RETURNING`); `GET /v1/devices/:id/commands?ack=1` declares an ack-capable agent and gets delivered-but-unacked commands re-offered after 120 s (max 3 attempts). Non-acking agents are unaffected.
- **New routes**: `POST /v1/devices/:id/commands/:commandId/ack` (device JWT) and `GET /v1/devices/:id/commands/history` (parent, non-destructive). `POST /v1/devices/:id/command` now returns `{id, status:"pending", expiresAt, …}`.
- **Security**: the drain is device-only (device JWT with matching `deviceId`); a parent token gets 403. Probe note **B11 is promoted to a gating check** (+ B11b history).
- Tests: `test/commands.test.ts` (8); existing fan-out tests now assert on the durable store instead of the Redis list. e2e pairs an agent device and walks pending → delivered → acked through the parent's history (56/56).
- Gates on this branch (lane-2, :3100): vitest **259/259**, `qa-probe` **79 passed · 0 failed · 2 targets**, `e2e` **56/56**.

### Added — Phase 2a: parents are notified (push + email) — KCL plan, ADR-0011
- **One alert path (`services/api/src/lib/alerts.ts`)**: `raiseAlert()` creates the row, publishes the WebSocket event and pushes to every parent device. All five producers (`/v1/alerts/internal`, `/v1/social/scan`, search-event, youtube-watch, geofence enter/exit) now use it; the audit had found push wired to one producer, as a `console.log`.
- **Push providers without SDKs**: FCM HTTP v1 with a service-account key (`src/lib/push/fcm.ts`) and APNs HTTP/2 with a p8 provider token (`src/lib/push/apns.ts`). Policy in `src/lib/push/notify.ts`: `PUSH_MIN_SEVERITY` floor (SOS/tamper always push), `DigestPrefs.pushEnabled`, platform routing, dead-token pruning on `UNREGISTERED`/410.
- **Parent push tokens**: `ParentPushToken` table (migration `0010_parent_push_tokens`), `POST /v1/me/push-token`, `DELETE /v1/me/push-token`, `GET /v1/me/push-tokens`.
- **Email provider** (`src/lib/email/`): Resend over HTTPS (`RESEND_API_KEY`, `EMAIL_FROM`) with a console fallback that never prints bodies in production. Bilingual EN+AR templates for password reset, invites and digests.
- **Password reset** emails a 15-minute link (`APP_PUBLIC_URL/reset?token=…`) and **no longer logs the token** (audit API-07). **Invites** email the accept link; the token is echoed in the response only without a provider and outside production. **Digests** are delivered by `src/jobs/digestScheduler.ts` (15-minute tick, `DIGEST_HOUR_UTC`, weekly on Sunday, Redis `SET NX` claim per family/day); `POST /v1/digests/send-now` now sends as well as renders.
- Tests: `test/push.test.ts` (10) and `test/email.test.ts` (13) cover the OAuth assertion, v1 message shape, APNs ES256 token and headers, token pruning, severity policy, templates, Resend envelope, reset/invite routes, scheduler claims and the `/v1/me` routes.
- Gates on this branch (lane-2 stack, port 3100): vitest **251/251**, `qa-probe` **77 passed · 0 failed · 2 targets**, `e2e` **50/50**.
- Not done here (board #50): parent-app token registration + notification permission flow (Phase 3), quiet hours/per-category prefs, delivery receipts.

### QA — TR-01/TR-02 verification, Redis hygiene tooling, two lifecycle findings (PR #59, issues #56/#57)
- **TR-01 PASS — Issue #53 re-verified on a non-UTC host.** `feat/backend-command-queue@c8676e2` was
  verified on an `Asia/Dubai` (UTC+04) database whose `DeviceCommand` columns were genuinely
  `timestamp(3) without time zone` before `migrate deploy` applied `0012_device_command_timestamptz`
  — i.e. the upgrade path, not a fresh schema. Results: **vitest 261/261 (22 files)**,
  **qa-probe 83 passed · 0 failed · 2 targets (J2, J6) · 1 note (E4)** including the new
  `K1`–`K4` device-drain/delivery/ack checks, **e2e 56/56**. Issue #53 closed as verified.
- **TR-02 PASS — `feat/backend-push-email@8276dd2`: vitest 252/252 (21 files), zero `TypeError` lines.**
- **Gate integrity re-checked on all three branches:** `qa-probe.mjs` vs `main` is 63/2 additions on the
  queue branch and 40/1 on each other branch, and every deletion is a promotion (a `note`→gating `check`
  for `B11`, a `target`→four gating checks for `J3`). No assertion relaxed anywhere.
- **New `services/api/scripts/cleanup-test-redis.mjs`** (dry run by default): classifies every Redis key,
  deletes only keys whose owning row is gone, and **never** touches `revoked:device:*` — that key is the
  control that makes an unpaired device's 10-year JWT answer `401`, not residue. Documented in
  `docs/TESTING.md` §5 and as a trap row.
- **Finding #56 (low):** per-device Redis keys have no owner. `revoked:device:*` is unbounded (10-year
  JWT, no TTL) and `cleanup-test-data.sql` cannot reach Redis. Also records my own mistake: I deleted 33
  such keys before reading the handler, and retract the "reap it on delete" suggestion — the fix is to
  **bound** the key by the token lifetime, never to reap it.
- **Finding #57 (low):** `refresh:index:<parentId>` (a Redis SET, no TTL) leaks a permanent member on
  every `/logout` (`routes/auth.ts:255-263`) and every naturally-expired session (`:242-244`); only
  rotation (`:247`) and logout-all (`:97`) clean up. 42 such keys with `TTL -1` after one day of runs.
- **`docs/TESTING.md`:** trap row for `e2e.mjs` aborting with `Error: ws timeout` (the harness races the
  server's socket registration and aborts with **0 FAILs recorded**, hiding the remaining checks) and for
  over-broad cleanup scripts.
- **Durable log:** full TR-01/TR-02 reply, the cadence agreement (30 min, checks at :23 and :53) and the
  correction above appended to `docs/QA/DISCUSSION-LOG.md`.
- **Verified:** all numbers above reproduced on the host PC against a live API on a non-UTC database;
  database restored to seed state (1 family / 1 parent / 1 child / 1 device / 0 pings / 3 seeded demo
  alerts / 2 geofences / 0 social / 0 invites / 0 commands) and Redis left with 170 keys, all with a TTL.

### Security — Issue #43 / Target J3: consent revocation now stops processing (PR #48)
- **Revocation endpoint** `POST /v1/family/children/:id/consent/revoke` and status `GET /v1/family/children/:id/consent`
  (`services/api/src/routes/family.ts`). The `/v1/consent/*` alias from the first draft was removed before merge.
- **Processing gate (ADR-0008 §2b).** While a child has no active consent, device ingestion
  (`/v1/location/ping`, `/v1/social/scan`, `/v1/alerts/internal`, `/v1/content/*`, `/v1/devices/:id/telemetry|activity`)
  and device reads (`GET /v1/rules/:childId`, `GET /v1/devices/:id/commands` with a device JWT) answer **428**.
  The first draft gated only the parent's configuration writes, which left the child's device collecting
  location and chat snippets after the parent had withdrawn consent — caught in the `KCL` review.
- **Safe-direction actions stay open (ADR-0008 §2c):** `resume`, `resume-internet`, device `unlock|resume|resume_internet|sos_clear`
  and child erasure are never consent-gated; enforcement commands (`lock`, `ring`, `pause`, …) are.
- **Agents are notified:** revoke enqueues `consent_revoked` to every device of the child and publishes a
  `consent_revoked` family event; re-grant enqueues `consent_granted`. Device pairings survive revocation.
- **Android agent** honours the contract: `consent_revoked` and a 428 from rules/commands pause enforcement,
  social capture, comms logging and location upload; `consent_granted` or a 200 resumes them
  (`RuleRepository.kt`, `CommandDispatcher.kt`, `LocationService.kt`).
- Migration `0009_consent_record_index` adds `ConsentRecord(childId, revokedAt)`.
- **Verified:** vitest 228/228 · `qa-probe` **77 passed · 0 failed · 2 targets (J2, J6)** on a live stack · `e2e` 50/50.
  Android change is unit-tested (`ConsentStateTest`) but **⚠️ not verified on hardware here** (no device in this environment).

### Fixed — Issue #43: Parental Consent Revocation and Enforcement Across Child-Scoped Writes (Target J3)
- **Consent Revocation Endpoints (`services/api`)**: Implemented `POST /v1/family/children/:id/consent/revoke` and alias `POST /v1/consent/:childId/revoke` allowing authenticated parents to withdraw consent for their child. Atomically marks active consent records as revoked (`revokedAt = now()`) and enforces strict family isolation (403 on cross-family attempts).
- **Active Consent Enforcement (`requireConsent` middleware, `services/api`)**: Gated all child-scoped write mutations on an active, non-revoked (`revokedAt IS NULL`), non-expired (`expiresAt IS NULL OR expiresAt > now()`), jurisdiction-matching `ConsentRecord` (HTTP 428 Precondition Required otherwise):
  - Rules: `PUT /v1/rules/:childId`, `PATCH /v1/rules/:childId`
  - Devices: `POST /v1/devices/register`, `POST /v1/devices/pair`, `POST /v1/devices/pair/claim`
  - Remote controls: `POST /v1/controls/children/:childId/pause-internet`, `POST /v1/controls/children/:childId/resume-internet`, `POST /v1/controls/children/:childId/bonus`, `POST /v1/controls/children/:childId/wind-down`
  - Geofences: `POST /v1/location/geofences`
  - Child profile: `PATCH /v1/family/children/:id`
- **Re-Granting Consent Flow**: Confirmed re-granting consent via `POST /v1/family/children/:id/consent` successfully unblocks subsequent child writes.
- **Probe J3 Promoted to Gate (`services/api/scripts/qa-probe.mjs`)**: Promoted target J3 to a gating assertion verifying revoke -> 428 on write, cross-family rejection (403), re-grant -> 200 unblocked, and alias route `/v1/consent/:childId/revoke` (74 passed, 0 failed, 2 targets, 2 notes).
- **Unit & Integration Tests**: Added `services/api/test/consent.test.ts` (14 tests) covering revocation, status, 428 precondition responses on revoked/expired/mismatched consent, and re-grant unblocking (224/224 tests passing).
- **Architecture Documentation**: Documented architectural decision and regulatory compliance in `docs/adr/0008-parental-consent-lifecycle-and-revocation.md`, superseding the tracked gap in ADR-0002.

### Fixed — CI: `secrets` in a step `if:` rejected the whole workflow (zero jobs ran on PR #49's first push)
- `.github/workflows/ci.yml`: the keystore step tested `secrets.OSRA_UPLOAD_KEYSTORE_B64` in `if:`; the secrets context is not available there, so GitHub rejected `ci.yml` and the run appeared only as a failed run named by its file path with no jobs — the "gate that looks present and does nothing" class again. The decision now happens inside the run body.
- `scripts/check-workflows.mjs`: new error for `secrets.` inside any `if:` expression. Verified: the broken file fails the linter (1 error), the fixed tree passes.

### Fixed — Phase 0 repo hygiene: the parent app's release build could not reach the network
- **`INTERNET` was declared only in the debug manifest** (`apps/parent-app/android/app/src/debug/AndroidManifest.xml`),
  so a `--release` build of the parent app could not log in. Moved to the main manifest with
  `ACCESS_NETWORK_STATE` and `POST_NOTIFICATIONS` (KCL review, `docs/QA/KCL-2026-10-16/AUDIT-API-AI-PARENT-APP.md`).
- **Google Maps key plumbing:** `com.google.android.geo.API_KEY` is now a manifest placeholder filled from
  `android/local.properties` or `MAPS_API_KEY`; without it the map rendered blank on every device.
- **Release signing plumbing:** `build.gradle.kts` uses an upload keystore when `OSRA_UPLOAD_KEYSTORE*` are set
  and falls back to the debug key otherwise; release builds now minify/shrink. Cleartext HTTP is permitted
  **only in debug** (`src/debug/res/xml/network_security_config.xml`); release is HTTPS-only.
- **CI becomes a store-readiness gate:** `parent-app` builds the release AAB and asserts `INTERNET` is in the
  bundled manifest; `child-android` runs `assembleRelease`; both upload artifacts (14-day retention).
- `docs/test-guides/CI-SECRETS.md` lists every secret the pipeline reads and what happens when one is missing.

### Fixed — Issue #45: YouTube Restricted Mode Enforcement Across API, Desktop Agent, and Parent App
- **API Persistence (`services/api`)**: Added `youtubeRestrictedMode` column (`@default("strict")`) to Prisma `RuleSet` model and schema migration `0008_youtube_restricted_mode`. Updated `toRow`, `toApiRuleSet`, and `defaultRuleSetRow` so `PUT /v1/rules/:childId` persists `youtubeRestrictedMode` ("strict" | "moderate" | "off") to PostgreSQL and subsequent `GET` requests return the persisted value. Verified via vitest covering PUT → GET round-trip across all three modes (206/206 passed).
- **Windows Desktop Agent Dynamic Header Selector (`apps/agent-desktop`)**: Added pure header selector `SafeSearch.GetYouTubeRestrictHeaderValue(mode)` mapping `"strict"` → `"Strict"`, `"moderate"` → `"Moderate"`, and `"off"` / unrecognized → `null`. Wired into `RuleSetSnapshot`, `RuleSetMapper.FromDto`, and `WebFilterProxy.cs` so `YouTube-Restrict` HTTP headers are dynamically set based on the active ruleset's `youtubeRestrictedMode` rather than hardcoding "Strict". Added xUnit theory unit tests in `SafeSearchTests.cs` (183/183 passed).
- **Parent App Reload Verification (`apps/parent-app`)**: Verified that when the API returns `youtubeRestrictedMode: 'off'`, `WebFilterRule.fromJson` retains `'off'` and `RulesEditorScreen` properly renders the `SegmentedButton` selected state as `{'off'}` without reverting to `'strict'`. Added regression widget test in `content_safety_test.dart` (103/103 passed, analyze clean).

### Fixed — Host Internet Disconnection & WinINET Proxy Dev Isolation (`apps/agent-desktop`)
- **Developer Machine Isolation (`apps/agent-desktop`)**: Added `SetSystemProxy` configuration property (default `true`) and `FS_SET_SYSTEM_PROXY=0` environment override (reading process and user environment) to `AgentConfig.cs` and `WebFilterProxy.cs`. Prevents agent from modifying WinINET registry settings when running in dev/test mode.
- **Unit Test Seam & Isolation (`apps/agent-desktop/tests`)**: Identified and fixed the root cause of developer proxy hijacking — `RuleSyncService` was calling static `WebFilterProxy.EnsureSystemProxy()` directly during tamper check tests. Added `EnsureProxyEnforced` seam in `RuleSyncService`, insulated `TamperVpnTests.cs` from registry mutations, and added unit tests (185/185 passed).
- **Process Exit Cleanup & WinINET Flush (`apps/agent-desktop`)**: Added `AppDomain.CurrentDomain.ProcessExit` handler in `Program.cs` ensuring orphaned proxy settings on 8877 are cleared on termination. Enhanced `reset-proxy.bat` to call `InternetSetOption` (`INTERNET_OPTION_SETTINGS_CHANGED` and `INTERNET_OPTION_REFRESH`), instantly applying direct connections without browser restarts.

### Fixed — Issue #47: Prisma Client Drift & Automatic Generation (`services/api`)
- **Automated Client Generation (`services/api/package.json`)**: Chained `prisma generate` into `"db:migrate": "prisma migrate deploy && prisma generate"` and added `"postinstall": "prisma generate"`.
- **Start Backend Script Guidance (`docs/test-guides/start-backend.example.bat`)**: Added `pnpm exec prisma generate` step after migration deploy with clear documentation on stopping running servers to avoid Windows query_engine DLL locks (`EPERM`).
- **Fail-Fast Boot Drift Guard (`services/api/src/lib/schemaSync.ts`, `server.ts`)**: Implemented `assertPrismaClientInSync` which inspects `information_schema.columns` vs Prisma DMMF scalar models on server boot. Fails fast with clear actionable remediation commands when migrations were applied without client generation (`pnpm exec prisma generate`) or client has fields not yet migrated (`pnpm exec prisma migrate deploy`).
- **Unit Tests & Documentation**: Added unit tests in `services/api/test/schema-sync.test.ts` (210/210 passed). Documented the trap and fix in `docs/TESTING.md` Section 6.

### Added — Parent App Content Safety Features
- **Search Safety View (`apps/parent-app`)**: Dedicated screen (`/child/:id/searches`, accessible from `ChildDetailScreen` AppBar action) consuming `GET /v1/content/searches?childId=...` (contract: `{ items: [...] }`). Renders flagged search queries with engine glyphs (Google, YouTube, Bing, DuckDuckGo), relative time, severity badges, and concern tags with pull-to-refresh.
- **YouTube Restricted Mode Toggle (`apps/parent-app`)**: Tri-state control (`Strict` / `Moderate` / `Off`) in `RulesEditorScreen` Web Filter tab. Enables parents to configure YouTube restriction levels, synchronizing via `WebFilterRule` to the backend rules API and Windows agent DTO.
- **Snippet Vault Decryption Modal (`apps/parent-app`)**: Reusable `SnippetVaultModal` displaying decrypted content from the AES-256-GCM vault, with encryption trust verification banner, clipboard copy utility, concern tags, and integrated bilingual `CoachCardSection` (EN/عربي). Wired into `SearchSafetyScreen` and `SocialScreen` / `ConcernsSection`.
- **Unit & Widget Test Suites**: Added `apps/parent-app/test/content_safety_test.dart` testing models, `SearchSafetyScreen`, `SnippetVaultModal` (including Arabic/English coaching toggle), `RulesEditorScreen` YouTube mode switching, and `ChildDetailScreen` navigation action. Maintained strict `kSocialApps` 8-app bound as per spec #2.

### Added — CI becomes a real gate
- **`scripts/check-workflows.mjs`** — a dependency-free validator for `.github/workflows/*.yml` that
  catches the traps YAML parsers accept but GitHub rejects (`uses:`+`run:` in one step, `with:` without
  `uses:`, a job without `runs-on:`, tabs) and flags gates that cannot fail (`|| echo`, `|| true`,
  `continue-on-error`).
- **`.github/workflows/workflow-lint.yml`** — runs that validator `--strict` from a *separate* file, so
  it still executes when a sibling workflow file is invalid.
- **`services/ai-engine/requirements-dev.txt`** — test-only dependencies (pytest, fastapi, pydantic,
  httpx). The heavy runtime deps (torch/transformers) stay in `requirements.txt` and are imported
  lazily, so the CI job runs in seconds.

### Fixed — CI
- **`child-android` never actually ran.** The job targeted `runs-on: macos-13`, a runner GitHub has
  retired, so it sat `queued` indefinitely — the Android suite and the `assembleDebug` guard were
  configured but never executed (the same class of failure as #37: a gate that looks present and does
  nothing). Moved to `ubuntu-latest`, which ships the Android SDK and needs no macOS.
- **`api` job green again**: CI never generated the Prisma client (`pnpm install` does not); locally
  `node_modules/.prisma` existed, which hid it. Added an explicit `prisma generate` step before the
  type-check. Symptom was `TS2694`/`TS7006` on every Prisma-touching route.
- **`ai-engine` job green again**: it exited `127` because `pytest` was missing; the job now installs
  the dev requirements (measured: **21 passed**, versus 18 passed + 1 skipped when `fastapi` is absent).
- **Removed the duplicate `child-ios` job** from `ci.yml`. It ran a subtly different
  `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 15'` and failed on simulator
  availability while the dedicated `ios-ci.yml` passed. One authoritative iOS gate is better than two
  that disagree.
- **`main-guard.yml`**: the last `|| true` was replaced with an explicit `if/else`, so the strict lint
  is meaningful and a genuine failure cannot be silently swallowed.

### Documentation
- `CHANGELOG.md` (this file), `docs/README.md` (documentation index), `docs/TESTING.md` (how to run and
  interpret every suite and gate), and `docs/adr/` (architecture decision records — the reasoning
  behind the decisions, not just the decisions).
- `docs/QA/TESTING-STRATEGY.md` — the agreed verification strategy: layer/ownership split, the
  **environment matrix** (timezone ≠ UTC, fresh DB, stale Prisma client, cleared build outputs, no
  credentials, rate-limit separation, OS paths, device), the rules both sides hold, the check cadence,
  and the anti-pattern checklist drawn from the failures actually hit in this repo.
- `AGENTS.md`: documentation is now part of the definition of done.

### Verification state at this point
- `qa-probe`: **73 passed · 0 failed · 3 targets · 2 notes** on `main@6818244`.
- CI: `api`, `parent-app`, `agent-desktop`, `ai-engine`, `workflow-lint` green; `child-android`
  (gradle tests + `assembleDebug`) queued at the time of writing.
- **Open by design** (need a human decision, tracked as probe targets): agent-request replay protection
  (`J2`), consent revocation enforcement (`J3`), and the global-secret fallback for devices without a
  per-device secret (`J6` / ask 16).
- **Verified on the physical device (SM-F721B, Android 16, build `main@6818244`)**: the agent no longer
  crashes on first run without location permission (`0` fatals), the location service starts **from the
  permission dialog without relaunching** (`isForeground=true types=0x00000008`), a relaunch of a paired
  app resumes tracking, and location actually reaches the server — `POST /v1/location/ping` → `201` with
  a persisted `LocationPing` row. Issues `#18` and `#38` closed with that evidence.
  *Lesson recorded:* my first two measurements said "no service"; the real cause was a **second**
  permission dialog (notifications) still holding the app behind a modal, so `onResume()` never ran. The
  harness, not the product — worth knowing because a tester will hit the same two dialogs.

---

## [2026-10-13] — P0 batch 2: content safety, screen time, proxy, CI syntax, location

### Security
- **Cross-family content write fixed (`#29`, critical).** `POST /v1/content/search-event` and
  `POST /v1/content/youtube-watch` authenticated the HMAC signature but never bound the body `childId`
  to the signing device, so one family's device could plant a fabricated, alarming search (e.g. a fake
  critical self-harm query) into *another* family's child timeline. Both routes now assert the device's
  own `childId` (and `deviceId` when supplied) and reject mismatches with `400`. Verified live: the
  cross-family call returns `400` and the target family sees nothing.
- **Screen-time accumulation fixed (`#31`).** `screenTimeTodayMinutes` returned only the last telemetry
  window (15 minutes of use read back as `5`) because the API summed a single overwritten Redis snapshot
  while the agent posts per-window deltas. Now accumulated per child/day
  (`usage:child:<childId>:<date>`, 48 h TTL). Verified: three 5-minute reports → **15**.
- **`reset-proxy.bat` completeness (`#32`).** It cleared `ProxyEnable`/`ProxyServer` but left the WinINET
  `Connections\DefaultConnectionSettings` blob pointing at the dead `127.0.0.1:8877`, so some clients
  stayed refused after an agent kill. Both the script and `WebFilterProxy`'s restore path now delete the
  Connections values. Verified functionally on the host.

### Fixed
- **Content-safety fallback coverage (`#30`).** The local self-harm pattern required the literal
  *"how to kill myself"*; *"how can I kill myself tonight"* was not flagged. Regex broadened; verified
  flagged `critical` / `self_harm` with the AI engine offline.
- **`ci.yml` syntax (`#37`).** A step carried both `uses:` and `run:`, so GitHub rejected the whole file
  and **every job was skipped** — `main` had no CI signal. Fixed, and the iOS gates no longer append
  `|| echo "…"` (they could not fail before).
- **Android build (`#33`).** `main` did not compile (`Unresolved reference: PackageManager` in
  `PairingActivity.kt`, introduced by the AND-13 fix itself), so no APK could be produced. Fixed.
- **Location FGS normal flow (`#18`, `#38`).** The agent no longer crashes when location permission is
  missing (it shows a "GRANT LOCATION PERMISSION" step), but in the normal flow the service still does
  not start: `startForegroundCompat()` catches `SecurityException` and returns `false` silently, and
  `showStatus()` never starts the service. Fix work in this batch; **hardware re-verification pending**.

### Added
- Track 1 (content safety) specs and routes: `docs/SPEC-CONTENT-SAFETY.md`,
  `POST /v1/content/search-event`, `POST /v1/content/youtube-watch`, `GET /v1/content/searches`.
- Track 2 (multimodal concern engine) spec: `docs/SPEC-AI-CONCERN-ENGINE.md`; Android monitored apps
  expanded to 10 (YouTube, YouTube Kids, Telegram, Reddit, Messenger join WhatsApp/Instagram/TikTok/
  Snapchat/Discord/Roblox).
- Headless iOS CI: `.github/workflows/ios-ci.yml` (SwiftPM build + `generic/platform=iOS Simulator` on
  `macos-14`), plus `docs/test-guides/IOS-CI-TESTING.md`.

---

## [2026-10-11 → 2026-10-12] — QA discipline, P1 batch, and the AI/content tracks

### Added
- **Adversarial acceptance gate** `services/api/scripts/qa-probe.mjs` — 70+ checks that try to *break*
  the documented invariants (family isolation, per-device HMAC, consent gate, revocation, token
  hygiene, input bounds, error hygiene, alert-category coverage). Exits non-zero while findings are
  open; the collaboration contract treats it as the merge gate.
- **Collaboration protocol** `AGENTS.md`: roles (implementation vs verification), definition of done,
  PR-only `main`, restatement-first pull requests, point-by-point evidence-based review, `needs-human`
  escalation, and device/environment hygiene.
- **Discussion log** `docs/QA/DISCUSSION-LOG.md` and the PR template
  `.github/PULL_REQUEST_TEMPLATE.md`.
- **Five platform audits** (`docs/QA/audits/`) and the consolidated `docs/QA/QA-REPORT-*.md`:
  48 findings with `file:line` evidence.
- **`/health/deep`** — readiness probe reporting `db`/`redis`, so an outage that leaves `/health` green
  can be diagnosed in one request.
- **Device/environment hygiene rule** (`AGENTS.md` §7) and
  `services/api/scripts/cleanup-test-data.sql` (dry-run by default).

### Fixed
- P1 batch: Android counter persistence / fail-closed rules / overlay bypasses (`#6`–`#8`), Flutter↔API
  contract mismatches and the refresh race (`#13`), Windows overlay/rename/screen-time issues (`#9`–`#11`),
  iOS shielding compile errors and store isolation (`#14`), plus `alwaysAllowedApps` round-tripping.
- API P0 bundle (`#1`–`#5`): per-device secrets no longer leak into parent payloads (an
  allowlist-by-omission bug), the iOS alert shape is accepted, the four previously-dropped alert
  categories work, cross-child injection is blocked, and device revocation applies to every route.
- `prisma generate` is required for type-checking (documented in CI).

### Infrastructure
- PostgreSQL runs as the auto-start Windows service `OSRA-Postgres` (immune to console/session reaping).
- `main` is PR-only. Branch protection is unavailable on free private repos, so the rule is enforced by
  `.githooks/pre-push` (verified) plus server-side detection in `main-guard.yml`; `main` was later made
  public, which allowed real branch protection to be switched on.

---

## [2026-09-18 → 2026-09-19] — Review response and token hygiene

### Security
- **Per-device HMAC secrets** replace the single shipped secret: a device receives its own secret once
  at pairing; the server verifies agent alerts against that device's key, and the global
  `INTERNAL_HMAC_SECRET` remains only as the AI-engine fallback.
- **Token hygiene**: refresh tokens rotate with reuse detection (a replayed token revokes the parent's
  sessions), `/logout` and `/logout-all`, revocation on password reset and MFA enable, device-token
  revocation on unpair, and single-use WebSocket tickets (`POST /v1/ws-ticket`) so JWTs never appear in
  URLs.
- MFA (TOTP) is optional and off by default; it is enforced only when a parent enables it, and TOTP
  replay fails closed in production when Redis is unavailable.
- Consent gate (HTTP 428) enforced at child creation; family isolation (403) on every data route.

### Fixed
- Wellbeing URL mismatch (the app called `/v1/wellbeing/:id`, the API served `/v1/reports/wellbeing/:id`).
- App Insights endpoint implemented instead of returning 404.
- Cross-platform pairing fixes: the child agent accepts LAN URLs without a scheme; the parent app
  normalises them the same way.
- **Server URL fields start blank** in every client (parent, child, Windows, iOS) — no pre-filled default
  that could point at a stale or built-in address.
- Android child agent: cleartext HTTP allowed for LAN test servers via a test-only network security
  config.

### Added
- First cross-platform artifacts in `dist/` (parent APK, child agent APK, Windows agent) and the
  tester-facing guides (`docs/test-guides/`).

---

## [2026-09-14 → 2026-09-16] — MVP and the world-class feature set

### Added
- Monorepo: Flutter parent dashboard, Kotlin Android agent, Swift iOS agent, .NET 8 Windows agent,
  Fastify/Prisma API, FastAPI AI engine, shared packages (types, consent SDK, crypto), infra templates.
- 29 "world-class" features: default-on 13-category protection, pause internet, WhatsApp/social AI
  monitoring with an encrypted snippet vault, calls & SMS timeline, install alerts with one-tap block,
  always-allowed apps, bonus time, wind-down, child SOS, multi-parent invites, tamper & VPN alerts,
  usage reports, wellbeing score, live activity chip, app insights, digest preferences, conversation
  coach (EN/عربي), routines, geofences, ring/lock/unlock.
- Seed data (demo family, child "Alex", device "Pixel 7a") and the live end-to-end suite
  `services/api/scripts/e2e.mjs` (50 checks).

<!--
When you add an entry:
1. Put user-visible changes under Added/Changed/Fixed/Removed/Security for the current release heading.
2. Reference the PR or issue number.
3. If something could not be verified where it was written, say so explicitly — an unverified claim in a
   changelog is worse than no changelog. `docs/TESTING.md` explains how each claim is checked.
-->
