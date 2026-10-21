# Changelog

All notable changes to OSRA are recorded here. Format: [Keep a Changelog](https://keepachangelog.com/),
versioning follows the product milestones rather than strict SemVer (this is pre-1.0 software).

Entries are grouped by the day the change landed on `main`, with the PR/issue references that carried
it. Anything marked **⚠️ not verified here** was written by an agent but could not be verified in the
environment where it was written — see `docs/QA/` for the verification state.

---

## [Unreleased]

### AI — second author pass on the two banks that carry the Phase 4 gate (plan 4.2)
- `self_harm` grows from 21/26 to **41/46** templates (EN/AR) and `grooming` from 20/23 to **40/43** —
  377 positive templates across the seven banks, up from 293. The generator caps each template at five
  rows, so the set grows through templates; at a fixed 65 rows per category the sample now draws from
  nearly twice as many independent patterns, which is what tightens the recall interval Claude's ruling
  is about.
- Registers added: for `self_harm` — a friend noticing the change, a note left to be found, a message to
  a sibling, being told it is attention-seeking, belongings given away, the morning after a bad night, a
  worried parent's message the child cannot answer, and the slide after a breakup or exam results. For
  `grooming` — a gift turned into a debt, a game or Discord chat moved into DMs, an adult who
  "understands you better than your mum", an image kept private, a standing payment, a phone offered
  against the parent's poverty, a named friend framed as jealous, a fake age admitted after trust, a
  first meeting already behind them, and a modelling "opportunity".
- The content rule holds through both passes: acts and substances named, no method, no dose, no price as
  a market, no sourcing route, no graphic detail. Two Arabic patterns were rewritten during the pass
  because `ل` + the definite article produced `لالمرشدة`; the replacement uses `حق`, which the validator
  cannot catch and the generated rows did.
- `EVAL.md` regenerated: English flags **30 %** of harmful rows (`sexual_content` 0.74,
  `substance_use` 0.57, `self_harm` 0.05, `grooming` 0.16, `violence` 0.13, `hate_speech` 0.00), Arabic
  0.00 throughout with `n/a`. Grooming's recall falling from 0.23 is the new registers doing their job —
  the rules layer keys on nothing they contain.
- **⚠️ not verified here:** the numbers are the author's run; a second agent has not re-run the table, and
  no native speaker has reviewed the new Arabic.

### AI — the labelled evaluation set and per-category, per-language scores (plan 4.2 + 4.3, WO-01)
- `services/ai-engine/eval/` now holds the labelled set the scorer is measured against: seven
  template banks (one per harmful category) in English and Arabic, expanded deterministically into
  **1,179 rows — 588 EN / 591 AR** (`eval/dataset.jsonl`), each tracing to `(bank, template_index,
  seed)`. **A positive must be labelable from the message alone**, which after Claude's #262 review
  means naming the thing — the vape, the photo, the beating at the gate — while still never containing
  method, dosage, price, sourcing route, weapon construction or graphic description. A true overlap
  carries both labels (`ALSO_LABELS_EN`/`_AR`): an adult asking a child for a photo is `grooming` and
  `sexual_content`, and a scorer answering either is right.
- **The set grows through templates, not fills.** Five rows per template is the cap and
  `--per-category` above `templates × 5` raises: one template filled 65 times is one item, not 65, and
  the recall interval it produces is a fiction. Claude's ruling keeps plan 4.2's 2,000 + 2,000 floor
  and puts the next author pass on `self_harm` and `grooming`, which carry the Phase 4 gate.
- `eval/run_eval.py` scores any scorer function and prints precision/recall **per category and per
  language**, plus the flag-level rates a parent feels (harmful rows flagged, and the false-positive
  rate split between generic safe text and hard negatives). An undefined rate prints `n/a`, not
  `0.00`: "nothing was flagged" is not "every flag was wrong".
- **The published numbers are the finding, not a regression:** `EVAL.md` (generated table,
  2026-10-21) shows Arabic recall **0.00 in all seven categories** and English flagging **32 %** of
  harmful rows, with the English categories that name a distinctive thing caught well
  (`sexual_content` 0.73, `substance_use` 0.58) and the ones phrased as intent missed
  (`self_harm` 0.02, `violence` 0.13, `hate_speech` 0.00). The rules layer is a set of English regular
  expressions; no Arabic string can match it. That is plan 4.1's premise, measured.
- CI (`.github/workflows/ci.yml`, `ai-engine`) validates the banks, fails if the committed dataset has
  drifted from them (`python -m eval.generate --check`) and runs the scorer. It deliberately sets no
  recall floor yet: a floor the current scorer cannot meet would be red from the day it lands, and the
  real floor arrives with 4.1.
- New: `services/ai-engine/EVAL.md` (published numbers + how to read them), `eval/README.md`,
  `eval/schema.md` (row format and how to add a public or parent-reported source).
- **⚠️ not verified here:** the numbers are the author's run on Python 3.13 / Windows; the committed
  dataset regenerates byte-identically in CI on Python 3.11 (`generate --check` passed there), but a
  second agent has not re-run the table yet.
### Comms — calls reach the parent with the time they happened, and a clock set forward cannot switch logging off (#260)
- **Every call and text was dated to the moment of the 5-minute flush.** `CommsLogger.flush()` built
  `ActivityEventDto(type, payload)` with no `ts`, so the server fell back to `new Date()`: two calls
  eight seconds apart arrived with the same timestamp, and a phone offline for hours dated all of its
  calls to the moment it reconnected. The DTO now carries `ts`, `flush()` sends
  `CommsEventTimestamps.isoUtc(e.timestamp)`, and the server keeps a reported time exactly — bounded
  at both ends: a time more than five minutes **ahead** is clamped (a child can set the clock forward
  once and pin a call to the top of the parent's list), and a time more than **seven days back** is
  floored (`activityEventTs` in `services/api/src/routes/devices.ts`), because retention deletes
  `ActivityEvent` by `ts` and an unbounded old timestamp is otherwise a deletion request against the
  90-day sweep. A phone offline for over a week has its older calls placed at the seven-day mark:
  misdated, but kept and visible.
- **The call watermark is `CallLog._ID`, not `DATE`.** `DATE` is when a call *started* but the row is
  written when it *ends*, so a 290-second call with a short call answered during it ends last and
  carries the older `DATE`: the short call raised the watermark past it and the long call was never
  read. `_ID` is monotonic and never reused, so the long call is simply the next id. The query is
  `_ID > ? AND DATE >= ?` ordered by `_ID`, keeping ADR-0008's grant floor on `DATE`; the old `DATE`
  watermark is converted once on upgrade (`newestCallIdUpTo`), and a consent reset clears the id
  watermark so the next harvest re-anchors at the re-grant rather than importing the paused window.
  **The upgrade anchor skips one call** — a long call still in progress across the last old-build
  harvest — but the old rule had already lost it, so this is forward-looking rather than a regression.
- **A stored grant time in the future is repaired, not clamped at read time.** `comms_call_since` /
  `comms_sms_since` are the read floor; if a child sets the clock forward and is re-granted consent
  there, clamping with `min(since, now)` keeps excluding every later call as `now` advances. The floor
  is re-anchored to now once and stored, the same way the SMS watermark is.
- **SMS keeps its `DATE` watermark but can no longer be stopped by the clock.** A stored watermark more
  than five minutes ahead of now means the clock moved back: the watermark re-anchors to now, one
  window is lost instead of every message after it, and a message dated beyond the skew is **not
  imported and does not advance the watermark** — it is re-selected and skipped each harvest until its
  date arrives (#264 files the remaining evasion).
- **A withdrawn phone no longer logs a full `HTTP 428` stack every 60 seconds**
  (`LocationService`); the transition is logged once, by `ConsentState`.
- Tests: `CommsWatermarkPolicyTest` +4 (call-waiting by id, clock-back, future row, clamped floor),
  new `CommsEventTimestampsTest` (4), `CommsGrantWiringTest` +4 pinning the query, the `ts` field and
  the 428 branch, and one API test asserting the reported time is preserved to the millisecond while a
  far-future one is clamped.
- **⚠️ not verified here:** the two phone rows — call waiting, and a clock set forward once — are
  Claude's, on the Flip4. The JVM tests hold the rules; no JVM test can insert `CallLog` rows.

### Child agent — a later call/SMS grant takes effect without a reboot, and history is never imported (#229)
- `CommsLogger` no longer sets one `started` flag before registering both `ContentObserver`s. Each
  stream has its own `callObserverRegistered` / `smsObserverRegistered` flag, and a stream is
  registered only when its permission is granted (`CommsObserverPolicy.shouldRegister`). A
  registration the provider refused without the permission (Samsung's call log) is now retried by
  `CommsCapture.onPermissionsChanged()`, which is called from `PairingActivity`'s permission-result
  callback, from `PairingActivity.onResume` and at the top of the 5-minute loop. A missing
  permission logs one INFO line and no stack (the #91 rule, which the registration path missed) —
  including the SMS `SecurityException` that used to log `W` with a stack.
- The first harvest of a stream no longer reads the phone's entire history. With no watermark,
  `harvestCalls()` / `harvestSms()` store `System.currentTimeMillis()` as both
  `comms_call_since` / `comms_sms_since` and the watermark and return without querying
  (`CommsWatermarkPolicy`). A withdrawal observed by the agent resets both keys, so a re-grant starts
  a new window at the re-grant time; `startFrom()` also floors every read at the stored grant time.
  ADR-0008 carries the sentence.
- Call rows: a row with no number and a VoIP `subscription_component_name` (Google Meet) is skipped
  rather than stored as an empty-number event, and a repeat of `(date, type, duration, component)`
  inside one harvest is dropped (`CommsRowPolicy`). The parent timeline now says "phone calls" in
  both languages, because app calls are not covered.
- New JVM tests: `CommsObserverPolicyTest`, `CommsWatermarkPolicyTest`, `CommsRowPolicyTest`, and
  `CommsGrantWiringTest` (the `CommandDispatcherAckTest` source-text shape) pinning the three
  `onPermissionsChanged()` call sites. **Not covered by a test:** the lifecycle itself (permission
  flip → observer registered → harvest). This suite is JUnit 4 with no Robolectric and no
  `androidTest` source set; the wiring is guarded, not executed. Author-run here:
  `./gradlew testPlayDebugUnitTest testFullDebugUnitTest` green; the watermark and row tests were
  shown red by reverting each rule alone. The TR-24 hardware re-test was not re-run here.

### Architecture — ADR-0028 accepted: AWS hosting approved
- Karim confirmed AWS as the cloud provider and approved the budget on 2026-10-21; ADR-0028 moves from proposed to accepted. The first infrastructure item, an HTTPS staging API in the UAE region built with Terraform, is filed for Kimi as #258 (roadmap 5.8). No code changed here.

### API — a password-reset link works once, and a failed confirm can still be retried (#167)
- `POST /v1/auth/reset/confirm` now consumes the link before doing any work: `/reset/request` mints
  the token with a `jti` and stores `reset:<jti>` → parent in Redis (`EX 900`), and the confirm
  consumes that record with the **Lua GET+DEL** script the pairing-code route already uses
  (`devices.ts:217`) and answers `401 invalid_or_expired_token` when it is gone. A link replayed
  inside its 15-minute window no longer sets a second password — before this, whoever saw the mail
  could take the account back after the parent had used it. Lua, not `GETDEL`: the shared test server
  runs Redis 5.0.14, where `GETDEL` (6.2+) is `ERR unknown command`, so the first draft of this
  change made every reset fail there. The shared `MockRedis.getdel` now throws that same error, so a
  future `GETDEL` fails the suite instead of the server.
- A second `/reset/request` supersedes the first: `reset:latest:<parentId>` names the only honoured
  `jti`, so the older link answers 401 even though it has not expired.
- `/reset/request` is rate-limited per address by its own 60-second cooldown:
  `SET reset:cooldown:<sha256(lowercased email)> 1 EX 60 NX`, claimed **before** the account lookup.
  Inside the window the answer is the same `{ok:true}` with no new link and no email — so a stranger
  can no longer keep superseding a parent's newest link or flood their inbox — and a Redis outage on
  that write answers `503 reset_unavailable` for a known and an unknown address alike, because the
  lookup is never reached.
  A failure after the claim — a database error on the lookup, a failed key write, or a provider refusal
  — releases it, so the parent's retry inside the minute sends a link instead of being told `{ok:true}`
  with nothing sent.
- The #162 retry contract is kept. If hashing, the password write or the session revocation fails
  after the consume, `reset:<jti>` is restored with the token's **remaining** lifetime (`exp − now`),
  so the client's retry with the same link succeeds; only a `200` has both stored the new password
  and revoked every refresh token and access token. Every post-consume failure replies explicitly —
  `503 reset_unavailable` — rather than rethrowing, because `server.ts`'s global handler maps anything
  Prisma-shaped to `400 invalid_input`, which no client retries. Known limit, accepted: a connection lost after the
  consume script has run leaves the link spent — the client sees a 5xx, its retry a 401, and asks for
  a new link; closing it needs an idempotency record.
- A parent that no longer exists is a `404 account_not_found`, decided from the update's
  `PrismaClientKnownRequestError` code `P2025` alone. The previous draft re-read the parent and used
  `.catch(() => null)`, which turned "cannot reach the database" into "account gone", deleted the
  link and broke the retry — the API-8 bug this change exists to fix, in its most common real cause.
- Tokens issued before this change have no `jti` and are refused at confirm (one forced re-login),
  the same migration cost ADR-0025 accepted for legacy refresh records. ADR-0025 carries the
  amendment.
- The global error handler moved to `src/lib/errorHandler.ts` (`registerErrorHandler`), still called
  by `server.ts` and now also by the test harness's `buildApp`, so a test sees the status production
  sends.
- Author-run here: `services/api` `pnpm test` 449/449 and `pnpm run build` clean; the new tests were
  shown red on the reverted branches (a Prisma-shaped update failure rethrown → `400`; the re-read
  during an outage → `404`). Live `qa-probe`/`e2e` were **not** run in this checkout, and the Lua
  consume is therefore **not** proven against a real Redis 5 here — the probe's G19 expectation was
  updated because a hand-signed reset token (no store record) is now refused at confirm.

### Parent app — an open map moves when a ping arrives, and a revoked consent refreshes (#253)
- `POST /v1/location/ping` now publishes one `location` event per upload carrying only
  `{ childId, ts }`, so a parent who keeps the map open sees the new position instead of the one from
  when the screen opened; coordinates stay off the Redis bus and the app refetches through the
  authorised `GET /v1/location/:childId/latest` (#242). The app also maps `consent_revoked` to a
  family-overview, location **and consent-screen** refresh, so another parent's open app stops showing
  a revoked child as consented without a pull-to-refresh. The published `ts` is the freshest ping in
  the upload, not the last array entry — since #243 the agent sends buffered pings after fresh ones, so
  the array order would advertise a stale time. Publishes are best-effort: a Redis failure never fails
  a stored upload.

### Parent app — a switch that promised a behaviour nobody implemented is gone (#245)
- The create-geofence dialog offered **"Apply school routine when here"** and stored `routineId`.
  Nothing carried fence state to the agent — its school rule is time-only — so arriving at the fence
  changed nothing, and the parent was promised a behaviour that did not exist. The switch is removed,
  the fence is created without `routineId`, and `docs/SPEC.md` states that the field has no effect
  until location-conditioned routines exist. Existing fences keep their `routineId`; the API is
  unchanged.


### API — a geofence arrival after a dropped connection is reported, and a stale gap is named (#243)
- **Missed arrival (found in review of the first cut):** the Android agent uploads fresh in-memory
  pings first and the older Room-buffered ones after (`LocationService.kt:262`), and the API judged
  the **last array element** — the newest of the *old* pings — so after any failed upload a real
  "Entered Home" never fired. The upload is now sorted by `timestamp` (a ping without one counts as
  received now) and judged from its **newest** ping; the stored previous ping is merged in, and the
  entry just before the newest is the "before". `pickTransitionPair()` makes that choice and
  `geofenceTransition()` decides the transition, both in `services/api/src/lib/geo.ts`.
- An enter/exit is no longer raised against a `before` that does not exist: when the device has
  **no previous ping** and the upload is a single ping (first ping after pairing, or the 30-day
  location window deleted the history) it is a **baseline** — no alert and no school-routine nudge.
  A previous ping at any age is still compared normally, so the ordinary overnight-off case keeps
  its "Left Home" and "Entered School". When the gap between "before" and "now" is **over 6 h** —
  the age of the position compared against, not the distance back to the oldest ping in the upload
  — the alert body says so ("No location for 13 h 50 min before this.") and the metadata carries
  `gapMinutes`: a dense buffered batch claims no quiet period, and a hole inside one is named.
  Still **no coordinates**, per #242. Contract in `docs/SPEC.md`, tests in
  `services/api/test/geofence.test.ts`.

### API / parent app — location history is kept 30 days, and the consent copy says so (#238)
- Children's **location history is kept 30 days**; raw app, web and chat rows stay at 90 and usage
  rollups at 365 (ADR-0028 decision 5, Karim 2026-10-20). `services/api/src/lib/usageModel.ts` adds
  `locationRetentionDays(env)` — `LOCATION_RETENTION_DAYS`, default 30, floor 7, never above
  `RETENTION_DAYS`; an unusable value falls back to `min(30, RETENTION_DAYS)` as its own explicit
  branch, not by clamp order. `applyRetention` now deletes `LocationPing` rows against that window
  while every other raw table keeps the 90-day cutoff; the function's doc comment says so.
- The parent app's withdrawal-confirmation copy (`consentRevokeDataRetention`, EN and AR) promised
  raw location, app, web and chat data at 90 days. It now says location 30 days, the rest 90, with
  the 365-day rollup sentence unchanged; generated localizations regenerated with `flutter gen-l10n`.
  `docs/SPEC.md` (consent withdrawal), `docs/TESTING.md` (env table), `services/api/.env.example` and
  `README.md` (limitations) carried the same single-window claim and are corrected.
- Tests: `services/api/test/usage-model.test.ts` — the 30-day default against a 90-day raw window,
  `LOCATION_RETENTION_DAYS=120` capped at 90, `"3"` floored at 7, `"abc"` falling back to
  `min(30, RETENTION_DAYS)`. The pre-existing assertion that expected `rawCutoff` for `locationPing`
  changed because the decision changed — not to make a failing check pass; with only `applyRetention`
  reverted to the shared cutoff, the 30-day and 7-day cases fail (expected `2026-09-16T02:00:00Z` /
  `2026-10-09T02:00:00Z`, received `2026-07-18T02:00:00Z`).
- **Not verified here:** no live stack, probe or e2e run in this session. The retention change itself
  needs no schema change — the `LocationPing.timestamp` column already exists and rows older than 30 days
  are removed by the next retention run rather than by a backfill. Migration `0022` in the same PR is not
  part of the retention change: it scrubs coordinates from geofence alerts, below.
- **Geofence alerts no longer carry the child's coordinates** (review of #242). A crossing used to store `lat`/`lng` in the alert's metadata, and alert rows are not touched by the retention job — so exact positions would have outlived the 30-day window the consent copy now promises. The alert names the fence; migration `0022` scrubs the coordinates from rows written before this change.

### Architecture — 30-day location history confirmed (ADR-0028)
- Karim chose 30 days over 90 for children's location history on 2026-10-20; ADR-0028 records the decision. Other raw data stays at 90 days and rollups at 365. The retention job change (a separate `LOCATION_RETENTION_DAYS`, default 30) is filed for Kimi in #238; no code changed here.

### Android / API — five remove-protection attempts are one page that says five (#227)
- Opening the admin-removal screen five times in five minutes used to send **five critical pages**:
  the accessibility guard enqueued a new `protection_screen_opened` alert on every attempt, and
  `AlertThrottlePolicy` was never consulted on that path. The agent now keeps a persisted per-device
  5-minute window: the first attempt pages immediately, later attempts update the same row's
  `attemptCount` (and body: "5 attempts were made …"), and a new window starts a new alert. The
  window cannot be reset by closing and reopening the screen; a failed POST keeps the count, so the
  next attempt still carries the lost one.
- API: `Alert.attemptCount` (migration `0021`, default 1) makes a repeated window key update the
  existing row in place and publish it for an open parent list, without a second push. A lower or
  equal count is treated as a retry and changes nothing. Alerts without an `attemptCount` — every
  other producer, including #225's `device_admin_removed` — keep their existing duplicate-is-a-no-op
  behaviour, so that event still produces one row and a `200` on retry.
- Tests: `GuardAttemptWindowTest` (five attempts → one window/count 5; boundary and exactly-at-boundary
  → new window; first attempt pages at count 1; a failed POST leaves the next count at 3; a retried
  POST of the same count posts once) and `alerts.test.ts` (repeat key updates the count with one
  `create` and no push; a new window inserts; an out-of-order lower count is ignored; the #225 cases
  pass unchanged). ADR-0029 records the choice of an in-place row over a closing notification.
  **⚠️ not verified here:** JVM/API suites only — no phone and no live stack, so the five-attempts →
  one-page row on hardware waits for the testing lane.
- **Review fixes (Claude, #235).** A higher count now also marks the row **unread again** (the badge and the list show that the child kept trying) while still never pushing; and the guard alert is unique per **window**, so a pending retry from an earlier window is no longer cancelled when the next window opens — attempts made while the phone was offline are delivered instead of dropped.

### Android — a command that succeeds acks, so history reaches `acked` instead of staying `delivered` (#231)
- The agent acked `failed` commands (issue #132) but never `ok`, so a `locate_now` that produced a fix, or a `lock` that applied, left its durable row `delivered` forever and `GET /v1/devices/:id/commands/history` told the parent the device had not confirmed it ran. `CommandDispatcher` now acks `ok` once per command: synchronous handlers when they return, `locate_now` only after `LocationService` has a fresh or recent cached fix (`detail.fix = fresh|cached`), and `wind_down` when the warning is posted and the timer armed (not when the lock fires). A handler that throws is acked `failed` with `reason: "command_failed"`, so a crash is reported rather than swallowed; a lost ack is logged once, not retried, and leaves the row `delivered` for the 120 s re-offer. **Verification on the Flip4 found two paths that still lied, and this PR closes them with `EnforceabilityPolicy`:** `ok` now means the effect is observable, and the ack names the path that produced it. `lock`/`pause` are `ok` only when one can actually put the screen up — `lockNow()` returned true (`detail.via = keyguard`), `Settings.canDrawOverlays` is granted (`overlay`), or our accessibility service is bound (`accessibility`; its own `onServiceConnected` state, not the persisted setting); otherwise `failed` with `reason: "lock_screen_unavailable"`, while `LockState` is still written so the lock applies when a grant returns. `pause_internet` is `failed` with `web_filter_not_set_up` when no VPN was consented or the OS no longer lets the tunnel start (the paused state is persisted regardless). A `locate_now` whose ping upload failed sends **no** ack — the buffered point is not observable — so the row is re-offered at 120 s. Unknown types are `failed` with `unsupported_command` and unparseable `bonus_time`/`wind_down` minutes with `invalid_payload` instead of staying `delivered` forever. The parent app maps the four reasons to EN/AR text. **⚠️ not verified here:** API unit tests and Android/Flutter JVM/unit suites only — no phone and no live stack in this run; the device-side refusals are shown by `_refusalMessage` only when a refusal arrives in the POST response; the history card still shows only the status, so surfacing the async `detail.reason` there is follow-up work.
- **`unlock`/`resume` no longer lie, and the lock screen follows the stored state (#233).** Two bugs in the same path, both measured on the Flip4 on 2026-10-20 and both found by the review of this PR at `a6584d3`:
  - **A refused unlock that had worked.** `EnforceabilityPolicy.unlockOutcome` refused with `unlock_screen_unavailable` whenever overlay and accessibility were off — but while our lock/pause screen is showing, our own visible window is what lets Android start `LockActivity` from the background (`BAL_ALLOW_VISIBLE_WINDOW`), so the unlock had already taken the screen down; and when nothing is showing, `LockState.clear` has already dropped the pending lock and there is nothing to take down. Rows 2, 5 and 6 all dismissed the screen and were acked `failed`, telling the parent the child's phone was still covered while it was free. `unlock`/`resume` now always ack `ok` with `detail.screen = dismissed|not_showing`, decided from a new `LockActivity.isShowing` (`@Volatile`, set in `onStart`, cleared in `onStop`). Showing: the dismiss launch happens. Not showing: **no launch is made**, because a blind launch only creates the blocked activity record below.
  - **A replayed intent cancelling a real lock (F2, older than this PR).** A refused `lock` creates an activity record that never starts; an `unlock` then queues `MODE_UNLOCK` on that record; when a later `lock` makes the launch allowed, the record starts with its old intents and the replayed `MODE_UNLOCK` finished the new lock screen **5 ms** after `on_create` — while the `lock` ack said `via=overlay`. `LockActivity` now draws what `LockState` says, not what the intent says: the decision lives in the pure `LockScreenPolicy.resolve(storedMode, intentMode)` (12-row table in `LockScreenPolicyTest`), the same check runs in `onResume` so an instance restored from Recents finishes too, and replayed intents converge on the stored mode.
  - The refusal path is gone rather than mapped: `unlock_screen_unavailable`, its EN/AR strings and generated l10n, the `EnforceabilityPolicy.UnlockPath` enum, the SPEC refusal line and the two parent widget tests that asserted the refusal are removed. `unlock`/`resume` keep sharing one handler, so `resume` cannot lose the outcome. Tests: `LockScreenPolicyTest` (12 combinations plus the F2 and unknown-state rows), `EnforceabilityPolicyTest` (both `detail.screen` values and the ack wire shape), and the `CommandDispatcher` source guard now pins `LockActivity.isShowing` instead of the old path table. **⚠️ not verified here:** JVM/Flutter suites only — no phone in this run. The hardware rows (2, 5, 6, 7 acked with the right `screen` and nothing left on screen; row 2 shows no `START … LockActivity`; the F2 sequence ends `acked via=overlay` with LockActivity focused) wait for the testing lane on this head.

### Architecture — production hosting, regions and scaling (ADR-0028, proposed)
- New `docs/adr/0028-hosting-regions-and-scaling.md`: AWS managed containers (ECS Fargate, RDS PostgreSQL with a standby, ElastiCache Valkey, SES, KMS); one independent stack per region, opened in Karim's launch order (2026-10-20): Middle East (UAE `me-central-1`), then Asia, Europe, the Americas; families routed by `Family.region`.
- Records the measured device load on `main` (~3 requests a minute, ~4,400 a day, per Android child phone) and decides push-first wake-ups before launch (target ~430 a day), a per-device capability list, a minimum-version gate and 30-day location retention.
- Cost estimate (on-demand list prices, a model, not quotes): ~$430 a month at 1k families, ~$1,200 at 10k, ~$5,700 at 100k, ~$40,500 at 1M. Docs only; no code changed.

### API / Android — a Locate that cannot work fails at once, and stays claimable for 20 minutes (#221 D1)
- A `locate_now` sent to a phone whose agent last reported **while-in-use only** location now comes back `failed` with `reason: "background_location_missing"` immediately; a phone with **no location permission at all** comes back `location_permission_missing`. The refusal only trusts a **fresh** report (younger than 20 minutes, one telemetry period plus its flex): an old, undated or absent report queues the command instead, because refusing on a stale grant tells a parent to fix something the child may already have fixed — measured on the Flip4, where "Allow all the time" was granted and a Locate four seconds later was still refused. The agent also uploads the grant as soon as it changes (pairing-screen resume and the permission callbacks) rather than waiting for the 15-minute tick. Before, the command sat `pending` for 10 minutes and turned `expired` unseen, because the 60-second poll only runs with the background grant (#155) and WorkManager ticks at most every 15 minutes. A phone that can answer is queued exactly as before, and one that has never reported is queued rather than guessed at. The command's lifetime is now 20 minutes (the 15-minute WorkManager floor plus its 5-minute flex) instead of 10; every other command type keeps its lifetime. The parent app now shows the refusal reason instead of "queued" — both for an immediate refusal and for one the phone reports later in its ack, which is surfaced on the delivery card and in the command history (`DeviceCommand.result.reason`); without that second path the device-side reasons would exist only in the API. **⚠️ not verified here:** API unit tests and an Android JVM suite only — no phone and no live stack in this run.

### Android — the status screen stops claiming location is active without "allow all the time" (#221 D3)
- The pairing status screen showed "✓ Location tracking: Active" whenever a fine/coarse grant existed and the foreground service was running. On Android 10+ that is a **while-in-use** grant: the service may hold a foreground session, but it cannot be started from the background, so `locate_now` and the periodic poll fail with `background_location_missing` — which is what the parent was told was "active".
- The line is now decided by `setup.LocationStatusPolicy` over `services.LocationStartPolicy.decide(...)` plus the service state: only a **background** grant with a running service shows the tick. While-in-use shows "⚠️ Location: needs "Allow all the time"" with a button that launches the separate background-location prompt (the same prompt onboarding uses). `LocationStatusPolicyTest` pins six cases, including that a while-in-use grant never shows the tick while the service runs, and that pre-Android-10 (where background is implied) still shows Active. **⚠️ not verified here:** JVM tests only; no phone in this run.

### CI / hardware — the app-list cadence harness takes its verdict after the sync (#221 D2)
- `scripts/hardware/app-list-cadence.ps1` compared the device against the API **once, before** the cadence wait, so an app uninstalled between syncs was always reported STALE — TR-48 run 2 reported FAIL while a fresh comparison after the sync matched 93/93.
- The script now re-reads the phone after **every** observed `appsReportedAt` change, records each comparison, and takes PASS/FAIL from the **last** one; the start-of-run comparison is `C0` information only, and no observed change means WAITING (exit 4). The self-test grew from 16 to 20 fixtures, including a package removed between marks that PASSes on the post-sync comparison and would have FAILed under the old rule. The verdict rule is also written into the script header and `docs/TESTING.md` §5i.

### Android — one deactivation pages once, and a fresh install is not tamper (#225)
- **Duplicate `device_admin_removed` page.** `GuardianAdminReceiver.onDisabled` records the disable
  timestamp and the alert now carries `<deviceId>|<type>|<disabledAtMs>` as a `dedupeKey`. The
  expedited worker and the 60-s drain in `LocationService` derive the same key from it, so the second
  run skips the POST; `admin_disabled_pending` is cleared only after a successful post, never on
  failure. The API adds `Alert.dedupeKey` (nullable, migration `0019`) with a partial unique index on
  `(deviceId, category, dedupeKey)`: a retry answers `200`, creates no second row, publishes no
  second realtime event and sends no second push. Alerts without a key are unchanged.
- **False "accessibility service was turned off" during setup.** The accessibility-off alert is now
  a true → false edge over a persisted observation (`AgentSettings.accessibilityWasEnabled`); a first
  observation that the service is off is silent. Re-pair clears the record, so a re-paired device
  with accessibility still off is silent too. A failed POST leaves `true` recorded and retries.
- **Overlay revocation on first sight, and the short accessibility component form (#225).**
  `overlayCheckOnce` applies the same true → false edge rule as accessibility, over a new persisted
  observation (`AgentSettings.overlayWasGranted` / `recordOverlayGranted`, cleared on re-pair): a
  fresh install that never granted "Display over other apps" is silent, while a recorded grant that
  is revoked still alerts once. The rule is one shared pure policy
  (`security.PermissionObservationPolicy`), and `AccessibilityOffPolicy` delegates to it. The
  accessibility parser now mirrors `ComponentName.unflattenFromString` in
  `security.AccessibilityServiceListPolicy`, so the short form
  `com.familyshield.agent/.services.AccessibilityMonitorService` counts as enabled in both the
  tamper check and `GrantChecks.accessibilityEnabled`, not only the fully-qualified form. Usage
  access has no alert site (only the setup checklist reads it), so no usage-access alert was added.
- Tests: `TamperAlertDedupeTest` (receiver alert + worker retry → one POST; new deactivation → new
  key; failed POST is not recorded), `AccessibilityOffPolicyTest` (first check off silent, on → off
  one alert), `PerPermissionEdgeTriggerTableTest` (accessibility and overlay: first observation off
  → 0 alerts, on → off → 1, off → off → 0) and `AccessibilityServiceListPolicyTest` (both component
  forms, other services/packages, `:subId`, null/blank, same-package different class); API
  `alerts.test.ts` (duplicate key `200`, one `create`; unique-collision race `200`).
- ADR-0027 records the rule and the rejected alternatives (dropping the drain, time-window
  throttling, a `(device, category)`-only index).

### Android — a deliberate parent-PIN removal is no longer reported as a stuck Knox record (#188)
- **Why.** Claude's verification of #218 measured that, after the parent removed protection with the
  PIN, the status screen inferred a stale Knox row from the mere presence of a Knox API and told the
  parent that only a factory reset could clear it — although re-activation through the sheet worked
  immediately. The inference predates #218 and belongs to #188.
- **Fix.** `DeviceAdminManager.removeAdmin()` now records a completed parent-PIN removal in
  `TamperState` (`admin_removed_by_parent`); `GuardianAdminReceiver.onEnabled` and a successful
  `enrolmentOutcome()` clear it. `AdminEnrolmentPolicy.classify` returns `STALE_KNOX_ADMIN` only for
  the observed "Admin is already added" shape — `RESULT_CANCELED` within 1 s of launching the sheet on
  a Knox device (`isAlreadyAddedRefusal`) — and `NOT_GRANTED` for an ordinary Cancel or Back, so the
  factory-reset wording appears only after the sheet itself refused. The status screen shows a calm
  "removed with the parent PIN" note under an alert-only tier and no longer offers the stale-record
  recovery pre-emptively.
- **Docs.** TR-41's acceptance cell quotes #170's original `dpm remove-active-admin` line again, with
  "procedure superseded by #217" after it, so the original contract and the reason the procedure
  changed are both visible; the row's status is unchanged.
- **Evidence.** See the PR: Android JVM test with the pre-#218 classifier restored fails
  `AdminEnrolmentPolicyTest > a returned sheet with no active admin on Samsung is an ordinary
  not-granted result`; the fixed tree is green. Not verified on hardware here — the phone was not
  touched, so the sheet's 1-second refusal window is measured by code/JVM only until a tester runs it.
- **Follow-up from #218's review (2026-10-20).** The parent-removal record is now written where the
  removal is confirmed: device-admin removal is asynchronous, so the `isAdminActive()` check at the end
  of `DeviceAdminManager.removeAdmin()` ran before it landed and the record stayed `false` (measured
  twice on the Flip4). `GuardianAdminReceiver.onDisabled` now records a parent removal inside the
  sanctioned window, so the status screen explains the deliberate removal instead of showing the
  stuck-record/factory-reset warning; an out-of-band removal still sets the pending flag and enqueues
  the tamper alert. JVM-tested at the policy level (`AdminDisabledPolicyTest`), and verified on the
  Flip4 by Claude at `7189de4` (#224): after a parent-PIN removal the record is `true` and the status
  screen says the removal was the parent's, while a child-initiated deactivation raises exactly one
  alert and leaves the record `false`.

### CI — the scope guard also catches a revert by value, and refuses an undeclared title
- The revert detector walks the last 30 first-parent merges on the base and fails when a PR restores a path's **pre-merge** blob while `main` still carries the merged one (additions, deletions and renames alike). A `revert(…)` title is the only way past it.
- A title that declares no kind is now **refused** rather than skipped, so the check cannot be avoided by wording.
- Self-test grew to five cases, two of them live: the stale-base squash (`6dd418f`) must fail under a `fix(…)` title, and the honest rebuild (`13faa6c`) must pass. That pair is the regression test for the near-miss of 2026-10-19.

### CI — a PR may only change what its title says it changes (stale-base guard)
- `scripts/check-pr-diff-scope.mjs` reads the declared kind from the PR title (`docs(`, `ci(`, `feat(`, `fix(` …) and the reality from `git diff --name-status`, and fails when a docs-titled PR touches code, when a ci-titled PR touches app code, or when a docs PR deletes files. Wired into `workflow-lint` for every PR, with a self-test that includes the negative control.
- Why: on 2026-10-19 a squash built from a `origin/main` that predated #218 produced a 24-file, +125/−503 diff that would have reverted the application label, `BlockSession`, the receiver rename and the cleanup-procedure change — and **every test stayed green**, because the tests proved the old tree worked. A suite proves code; it cannot prove the diff is the change intended.

### Process — the auto-close trap, folded into the row that already existed
- A PR body that negated a closing keyword still closed the issue: the parser reads the keyword, not the sentence. The trap row in `docs/TESTING.md` §6 now adds the two things the first version missed: commit messages that land on `main` count as well (a merge commit closed it a second time), and the recovery is to reopen the issue and say why on it.

### Android — the system sheets name the app, the block screen follows the app in front, and cleanup stops stranding Samsung admins (#217)
- **Why.** Claude's 2026-10-19 Flip4 re-tests (#217) measured three defects and one procedure trap:
  the camera and device-admin sheets called the app `com.familyshield.agent.FamilyShieldApp`; a second
  block screen kept the first app's name and would have asked the parent to unblock the **wrong** app;
  and TR-41's documented cleanup (`dpm remove-active-admin`) stranded a Knox admin record, so the app
  could no longer activate device admin through the system sheet.
- **Labelling (finding 2).** `<application>` in `app/src/main/AndroidManifest.xml` now declares
  `android:label="@string/app_name"` and `android:icon="@drawable/ic_app"`, and the accessibility
  service declares `android:label="@string/accessibility_service_label"`. `PlayMergedManifestTest` /
  `FullMergedManifestTest` assert the merged application label/icon and the service label in both
  flavours; `scripts/check-merged-manifest-gate.mjs` requires the new assertions.
- **Block screen (finding 3).** `BlockActivity` is `singleTask`; it now overrides `onNewIntent` →
  `setIntent`, and a new `BlockSession` holds the request in Compose state instead of reading the
  intent once. Both "Request access" and "Exit to Home screen" use the package currently on screen,
  the screen shows `PackageManager.getApplicationLabel` (package id as fallback), and the composable is
  keyed on the package so "Request sent" does not leak to the next app. `BlockSessionTest` drives two
  intents with different packages and asserts both the label and the action targets change.
- **Cleanup procedure (finding 1).** `docs/TESTING.md` §5/§5a/§5f/§5g/§7, TR-41's row and
  `scripts/hardware/android-pairing-time.ps1` now end debug runs with the app's **REMOVE PROTECTION
  (PARENT PIN)** (Knox-aware since #186) followed by `adb uninstall`. `dpm remove-active-admin` survives
  only as a last resort, with the Samsung warning; TR-41 still proves `testOnlyAdmin=true` from
  `dumpsys` and no longer needs the shell removal.
- **Second component rename.** `security.ParentalAdminReceiver` → `security.GuardianAdminReceiver`,
  with `DeviceAdminManager`, the manifest, the tests, the hardware harness and the docs moved together.
  `ParentalAdminReceiver` had already replaced `FamilyShieldDeviceAdmin` in #209; the second rename was
  needed because the **cleanup command**, not the class name, created the stale Knox row. The app's own
  removal path was measured not to clear that row (Claude's #217 sequence), so a rename is the recovery.
- **Evidence (author's run, no hardware).** `./gradlew testPlayDebugUnitTest testFullDebugUnitTest
  assemblePlayDebug --no-daemon` → **BUILD SUCCESSFUL in 3m 22s**, **373 tests / 0 skipped / 0 failed**
  in each flavour (56 suites; +6 over 367: four `BlockSessionTest` cases plus one merged-manifest
  assertion per flavour). Fail-before for finding 3: with `BlockSession.apply` mutated back to read-once,
  `testPlayDebugUnitTest --tests "*BlockSessionTest"` failed **3 of 4** (the second-intent, the
  render-notification and the blank-package cases). `node scripts/check-merged-manifest-gate.mjs` →
  **2 result set(s) checked, all assertions ran and passed** (Play 9, Full 7 in both); `node
  scripts/check-docs-links.mjs` → **0 broken out of 146**; `aapt2 dump badging app-play-debug.apk` →
  `application-label:'OSRA'`, `application-icon-160:'res/drawable/ic_app.xml'`. All four merged
  manifests carry `android:label="@string/app_name"` and `android:icon="@drawable/ic_app"`.
- **⚠️ Not verified here.** The phone was not touched. The camera prompt and a second block screen on
  the Flip4 remain for the tester; and no one has yet activated `GuardianAdminReceiver` through the
  sheet on the handset, so the #217 recovery is unproven on that phone. This is the author's software
  run, not verification.
### QA — #206 Group 3 re-verification results and doc fixes (Claude, 2026-10-19)
- **Why.** Karim's #206 mandate: every merge since 2026-10-18 re-tested on current `main` by a non-author.
- **What.** `docs/QA/TEST-REQUESTS.md` status column for TR-67…TR-94 (TR-93 is Claude's own and left for Kimi):
  19 verified, 7 verified with a note, 1 FAIL (TR-80: #136 auto-closed through a negated closing keyword).
  Fixes found by the reads: AGENTS.md verified-gate row now states the Kimi carve-out and carry-forward;
  ROADMAP row 2.2 gains #93's sha and row 3.1 records #161 as merged; TR-82/84/86 command paths corrected;
  TESTING.md §6 gains the closing-keyword trap. Board message added.
- **Evidence.** `main@1296c79`: check-workflows --strict 0/0, docs links 0/146, merged-manifest gate red on three
  doctored inputs, probe integrity 0 removed, ledger sha check 73 rows 0 problems; Group 2 runs still hold (no code
  change since `2f940cf`). Roadmap: Phase 0 quality gate (#206).

### QA — #206 Group 2 re-verification results (Claude, 2026-10-19)
- **Why.** Karim's #206 mandate: every merge since 2026-10-18 re-tested on current `main` by a non-author.
  Under the 2026-10-19 role re-cut Claude runs the remaining re-tests.
- **What.** `docs/QA/TEST-REQUESTS.md` status column for TR-48…TR-66: 14 verified; TR-48, TR-51, TR-52,
  TR-53, TR-54 software half verified with the manual half named and owned. Board message added.
- **Evidence.** `main@2f940cf`: vitest 395/395, probe 151/0, e2e 71/71, Android JVM 734/734, Flutter 243/243,
  analyze clean. Roadmap: Phase 0 quality gate (#206).

### Process — roles re-cut: Claude does architecture and all testing; Antigravity inactive (maintainer, 2026-10-19)
- **Why.** The maintainer re-cut the team at 17:22Z: once Antigravity files the rows already in flight
  (Group 1 hardware re-runs, TR-52), Claude does architecture and testing, Kimi stays lead developer, and
  Antigravity takes no testing tasks until further notice.
- **What.** AGENTS.md §1 role table and quote, §2 step 3 and §6.5 rules 2, 3 and 6 now name Claude as the
  verifier. A Claude-authored PR is verified by Kimi Code (CI allows it only with no Kimi commits) or the
  maintainer. `verified-gate` is unchanged.

### Testing — harnesses for the two #206 hardware rows (TR-48, TR-51/52/53)
- **Why.** Claude's #206 ruling left five acceptance lines with `no current check`; two of them are
  scriptable and this PR builds those harnesses. Neither changes product code.
- **TR-48 (#201).** `scripts/hardware/app-list-cadence.ps1` compares the launchable third-party
  packages the device reports (`pm list packages -3` plus the launcher query) with the inventory the
  API stored (`GET /v1/devices/:id/apps`), in both directions, with the documented 60 s clock-skew
  tolerance for apps installed after the last sync. It then requires two consecutive
  `appsReportedAt` values 14–16 minutes apart and prints PASS/FAIL; an unobserved second value is
  WAITING and exit 4, never an invented timestamp. `-SelfTest` covers extra/missing/tolerance and
  the 14/15/16-minute window without a phone, and runs in `workflow-lint`.
- **TR-51/52/53 (#189, #179, #153).** `android-pairing-time.ps1 -Human` timestamps only: no adb, no
  input events, no UI dumps. The observer presses Enter (or drops `-MarkerFile`) at welcome, signed
  in, child added, QR shown, child scanned and "Protection: on"; it writes
  `RESULTS-PAIRING-HUMAN.md`/`.json` and prints the total against 300 s as information, never as a
  pass or fail. The existing machine-driven mode remains TR-23's proxy. `-Human -SelfTest` checks
  the arithmetic, the informational verdict and both files, and runs in `workflow-lint`.
- **Docs.** `docs/TESTING.md` §5i describes both; TR-48 and TR-51/52/53 now name the commands in
  `docs/QA/TEST-REQUESTS.md` (their status is unchanged).
- **⚠️ Not verified here.** The live TR-48 path was exercised read-only against the Flip4 with a
  local fixture API (93 launchable user apps; PASS/FAIL and WAITING/exit-4 paths both observed), but
  the real API cadence was **not** observed: the phone is clean and has no paired agent. No human
  five-minute run was performed. Those remain for Antigravity/the maintainer, and the rows stay open
  until they happen.

### Process — verified-gate carries a signature across a merge of main (#207)
- **Why.** `main` requires branches to be up to date (`strict`), so each merge forced every queued PR to
  merge `main` in and be signed again with nothing of its own changed; #205 was the first case.
- **What.** `verified-gate.yml` now checks out the PR with full history. A signature at sha S still counts
  for head H when only merge commits (not on `main`) were added after S and the PR's own diff from its
  merge-base has the same `git patch-id --stable` at S and H. `strict` stays on: what merges is still a
  tree whose own change someone verified. AGENTS.md §6.5 rule 6 updated.
- **Checked.** On #205: signature `6778f39`, head `fd169d4` → 0 non-merge commits outside `main`, patch-id
  equal at both (carried). Against `6778f39^` → 1 non-merge commit (refused).
### Android — the device-admin receiver is renamed so a poisoned Knox row needs no factory reset (#202)
- **Why.** Samsung's Knox admin registry matches **component + user**, not uid. The Flip4's stale row
  for `com.familyshield.agent/.security.FamilyShieldDeviceAdmin` made every activation through the
  system sheet fail with `Admin is already added`, and it survived uninstall/reinstall with a new uid
  (#181, #185). A component name Knox has never seen is not in that list, so a rename is the recovery.
- **Rename.** `security.FamilyShieldDeviceAdmin` → `security.ParentalAdminReceiver`. The manifest entry,
  `DeviceAdminManager`, `ParentalAdminReceiver.COMPONENT_CLASS`, the receiver's KDoc cross-references
  and `scripts/hardware/android-pairing-time.ps1` move together. Policies are unchanged (`force-lock`,
  `watch-login`, ADR-0010); there is no installed customer base, so nothing is migrated.
- **Pins.** New `AdminReceiverContractTest` (JVM) asserts the constant equals the class, the manifest
  receiver resolves to that class, the admin contract (permission, meta-data, intent action) is intact,
  and `res/xml/device_admin.xml` declares exactly the reviewed policy set. `PlayMergedManifestTest` /
  `FullMergedManifestTest` assert the renamed component in both merged manifests, and
  `scripts/check-merged-manifest-gate.mjs` now requires those assertions.
- **Docs.** `docs/TESTING.md` §5 says never to run `dpm remove-active-admin` on an admin activated
  through the sheet, and §6 records the component rename as the recovery path for a stale Knox row.
- **Evidence.** `./gradlew testPlayDebugUnitTest testFullDebugUnitTest assemblePlayDebug
  --no-daemon` → **BUILD SUCCESSFUL**, 367 tests / 0 skipped / 0 failures in each flavour;
  `node scripts/check-merged-manifest-gate.mjs` → **2 result set(s) checked, all assertions ran and
  passed** (Play 8, Full 6 in both). Hardware (Full debug, test-only — **not gate evidence**, #178):
  on the Flip4 the system sheet returned `device_policy after Activate: True` and
  `dumpsys device_policy` shows `com.familyshield.agent/.security.ParentalAdminReceiver` with
  `policies: watch-login, force-lock`; remove protection → `alert-only` / 0 admins → re-activate
  through the sheet → `✓ Protection: device admin` again (#187 AC1's second half). The in-app
  removal logged `protection removed via AOSP` (the Knox `setActiveAdmin(false)` call returned false,
  so #186's fallback ran); re-enrolment still succeeded. This is the author's run — a tester re-run
  is what makes it verification. Evidence: `C:\KARIM\.tmp-202\hw202\pairing-time.log`.

### Roadmap 3.8 — the design system reaches the last five screens and alert severity
- **Why.** #145 shipped the token layer and dark theme but deliberately left five screens on their own
  spacing and colours, and alert severity was still duplicated `Colors.red/amber/blue` switches. Dark
  mode on those screens was untested, and one severity string could render three different ways.
- **Screens.** `family_map_screen.dart`, `rules_editor_screen.dart`, `social_screen.dart`,
  `search_safety_screen.dart` and `settings/digest_prefs_screen.dart` now take colours, gaps, radii and
  text styles from `AppTokens` / `AppType` / `AppSpace` / `AppRadius`. No raw `Color(0x…)` or `Colors.*`
  remains in them; copy, widget keys, API calls and the 320×568 guarantees are unchanged.
- **Severity.** `AppTokens.severityDot` / `severityText` are the single lookup for
  `critical` / `warning` / anything-else, shared by the alerts feed, `AlertTile`, the concerns vault,
  search safety and the snippet-vault modal. The light dot values stay `Colors.red` / `Colors.amber` /
  `Colors.blue` (same runtime type, so `widget_screens_test.dart` still pins them); dark mode maps to
  `#FF8A80` / `#FFD54F` / `#82B1FF`. New `severityCriticalText` / `severityWarningText` /
  `severityInfoText` roles give labels a readable foreground instead of using the amber dot as text
  (light `#B3261E` / `#7A5900` / `#0B57D0`, dark `#FFB4AB` / `#FFD37A` / `#82B1FF`). `onOk` resolves
  the swipe-to-acknowledge pair; its light fill moves from Material green `#4CAF50` (white icon,
  2.78:1) to the tokens' `ok` `#1B5E20` (white icon, 7.87:1), dark `#7CDB9E` / `#00391B`.
- **Layout.** The search-safety card header overflowed 320 px by ~84 px (two rows; pre-existing, the old
  suite never rendered it at 320). The engine/time label is now `Expanded` with an ellipsis, so the new
  dark 320 test passes without changing copy or keys.
- **Tests.** `test/design_system_test.dart` grows from 8 to 19: dark rendering of all nine migrated
  screens at 320×568, dark severity dots in the alerts feed, dark severity labels in search safety,
  light-pin preservation, case-insensitive lookup, and computed contrast for every new text pair on both
  surfaces and on the 7 %/15 % card tints. Worst measured: 4.70:1 (light critical label on its 15 %
  tint); `onOk` on `ok` 7.87:1 light and 7.80:1 dark.
- **Evidence.** `flutter test` **237 passed**; `flutter analyze` **No issues found**; ARB key/placeholder
  parity unchanged and green. **Not verified here:** the physical phone is unavailable (stale Knox admin
  row, #181) and the change is widget-level, so no hardware claim is made; no merge sha and no
  independent verification yet.

### Roadmap 3.8 — auth and family join the design system (follow-up to #203)
- **Why.** #203 finished the five screens named in the original 3.8 scope but left the auth entry
  (`login` / `register`) and family management on their own spacing, so dark mode on those two screens
  had never been rendered at 320×568 and their form radii ignored `AppRadius`.
- **Screens.** `auth/login_screen.dart`, `auth/mfa_recovery_screen.dart` and `family/family_screen.dart`
  now take every gap from `AppSpace`, every input/control radius from `AppRadius.sm`, and their error
  foreground from `AppTokens.danger`; body/secondary text stays on `ThemeData.textTheme`. No raw
  `Color(0x…)` or `Colors.*` remains in the two feature folders. Copy, widget keys, API calls and the
  320×568 guarantees are unchanged.
- **Layout.** Two pre-existing 320 px overflows surfaced when these screens were first rendered at that
  width (the old suite only used the 800×600 default): the region dropdown in the expanded register form
  overflowed by 42 px, and the role dropdown in the invite dialog by 9.4 px. Both now set
  `isExpanded: true`, matching the flex/ellipsis treatment #203 used; no copy or key changed.
- **Tests.** `test/design_system_test.dart` grows from 19 to 25: dark rendering at 320×568 for login,
  MFA recovery and family members, the expanded register form and the recovery entry at 320×568, the
  invite dialog at 320×568, and a computed contrast check for the pairs these screens actually use —
  `danger` on `surface` (login error) 6.54:1 light / 10.95:1 dark, and `danger` on `surfaceContainer`
  (invite-dialog error) 6.04:1 light / 10.06:1 dark, all ≥ 4.5:1. ARB key/placeholder parity unchanged.
- **Deliberate exceptions.** The 18×18 in-button progress spinners, the 72 px shield icon, the 420 px
  form reading width and the invite accept token's literal `monospace`/bold style stay literal: they
  are control sizes or a style with no token role (`AppType.recoveryCode` is 16 px with 0.4 tracking
  and would change the dialog's 320 px layout). Family copy remains untranslated as before; no new
  user-visible string was added.
- **Evidence.** `flutter test` **243 passed**; `flutter analyze` **No issues found**. **Not verified
  here:** the physical phone is unavailable (stale Knox admin row, #181) and the change is widget-level,
  so no hardware claim is made; no merge sha and no independent verification yet.

### Roadmap 3.4 — the installed-app inventory and a Rules picker built from real apps
- **Why.** An app rule used to require a typed package id and a typed label. A parent cannot read a
  package id from the launcher, so the typed path produced typos and rules for apps that were not
  installed at all.
- **Device.** The child agent reports its launcher-visible apps — package id, launcher label and the
  OS system flag — on the existing 15-minute telemetry tick. `InstalledAppsPolicy` (pure Kotlin) is
  the list builder: launcher-only, one row per package (first wins), trimmed label with the package
  id as fallback, 100-character label cap, 500-app cap, and a SHA-256 fingerprint so an unchanged
  list costs no network. `InstalledAppsCollector` uses the `MAIN`/`LAUNCHER` intent, which the
  manifest already declares under `<queries>` (since #165), so this adds **no** `QUERY_ALL_PACKAGES`
  and no Play permission. No icons, usage stats or launch counts are sent.
- **API.** New `DeviceApp` table plus `Device.appsReportedAt/appsVersion` (`0018_device_apps`).
  `POST /v1/devices/:id/apps` is a device-JWT, self-scoped write (`requireFamily` +
  `requireOwnDevice`, the same composition as telemetry), honours consent (428), dedupes, caps and
  replaces the list wholesale (an empty report clears it). `GET /v1/devices/:id/apps` is
  parent-only, family-scoped and gated on the `rules` permission; it returns contract version 1 and
  `reportedAt` (null before the first report). The erasure cascade deletes the inventory before the
  device rows so the GDPR row counts stay complete.
- **Parent app.** The Rules editor's Apps tab now offers **Choose from child's apps**: search over
  label and package id, system apps hidden until the filter is switched on, already-ruled apps shown
  disabled with a check mark, and an empty state that says the list appears after the next check-in.
  The typed package-id dialog is still there for an app the child has not reported yet. Every new
  string exists in `app_en.arb` and `app_ar.arb`; the picker is tested in Arabic RTL at 320×568.
- **Tests / evidence.** `pnpm --filter @familyshield/api test` **395 passed** (the new
  `device-apps.test.ts` was 9/9 failing with 404 before the route existed); probe **151 passed / 0
  failed** including G24–G29 (upload/read/dedupe/family isolation/self-scope/bounds/replace/clear),
  J3e (consent 428) and N6f (`rules` permission); e2e **71 passed / 0 failed**, whose erasure row
  counts show `deviceApp: 2` deleted and 0 left; `./gradlew testPlayDebugUnitTest
  testFullDebugUnitTest` **362 tests / 0 failures / 0 errors / 0 skipped, 54 suites per flavour**,
  `BUILD SUCCESSFUL`; `flutter test` **226 passed** and `flutter analyze` **No issues found**.
- **Not verified here.** The physical phone was unavailable (stale Knox admin row, issue #181), so
  the real PackageManager output, the 15-minute upload cadence and the picker against a real handset
  were **not** observed. The JVM suite covers the pure list builder, not the Android query. No merge
  sha and no independent verification yet.

### Process — verified-gate: Kimi cannot verify a PR with Kimi commits, and the signer is the last signature
- **Why.** #196 was merged on a `— Kimi Code` verification at a head that contained Kimi's own commit to
  the gate (7e1236d), and that comment also quoted `— Claude`, which the substring match counted as a
  Claude signature. Either hole alone let an author verify their own change.
- **What.** `verified-gate.yml` counts Kimi-authored non-merge commits on the PR (commit email
  `kimi@familyshield.local`) and ignores a `— Kimi Code` verification when there are any; the signer is
  the **last** `— Antigravity|Claude|Kimi Code` in a comment, not any mention. AGENTS.md §6.5 rule 6
  says so.
- **Tested.** `check-workflows.mjs --strict` 0/0; PyYAML parses the file; the step run locally: #196
  (Kimi verification + Kimi commit) now fails, #195 without label fails, a Claude-signed stub that
  mentions Kimi earlier passes.
### Hardware tooling — a testOnly/debuggable build is not gate evidence (issue #178)
- **Why.** Since #170 every debug APK declares `android:testOnly="true"` and is `debuggable`. Such a
  build can be replaced with `adb install -r` without a signature match, its device admin can be
  removed with `dpm`, and its process is debuggable — so the Phase 1 tamper rows (probe rows 1, 2, 10
  and the force-stop guard) measured on it say nothing about the release artefact. They had been
  measured on debug builds for weeks, and nothing in the probe or the gate said so.
- **What.** New pure decision `scripts/hardware/classify-build.ps1` (`Get-BuildKind`) classifies
  `adb shell dumpsys package <pkg>` as `release`, `test-only`, `debuggable`, `not-installed` or
  `unknown` (precedence `test-only` > `debuggable` > `release`; another package's flags in the same
  dump are ignored). `scripts/hardware/android-bypass-probe.ps1` calls it before the first row, with
  `adb shell run-as <pkg> true` as a second signal, and:
  - refuses a `test-only`/`debuggable` build with **exit 3** and a message naming the flags — nothing
    is measured;
  - under `-AllowTestBuild`, prefixes every row's evidence with
    `NOT EVIDENCE (testOnly/debuggable build)`, sets `gateEligible: false` (plus `buildKind`,
    `buildFlags`, `testOnly`, `debuggable`) in `bypass-probe.json`, and prints that the run cannot
    open a gate;
  - aborts with exit 2 when the package is not installed or its flags cannot be read, instead of
    guessing `release`;
  - `-CheckBuild` prints the decision and exits (0 release, 3 blocked) without running a row.
  `scripts/hardware/android-pairing-time.ps1` records the build kind per run and notes that numbers
  from a non-release build are a proxy.
- **Drive-by fix found while testing it.** The probe could not be invoked at all on Windows
  PowerShell 5.1: `[string]$Db` collides with the common parameter `-Debug`'s `db` alias
  (`The parameter 'Db' cannot be specified because it conflicts with the parameter alias of the same
  name for parameter 'Debug'`). Renamed to `$DbUrl`. No caller passed `-Db`.
- **Tests / evidence.** `pwsh -NoProfile -File scripts/hardware/classify-build.ps1 -SelfTest` →
  **8/8 fixtures passed**, including real Flip4 `dumpsys package` output (a release install) and the
  real `Unable to find package: …` line; a deliberately flipped fixture turns it red (exit 1). The
  probe's three outcomes were exercised against a fake `adb`: test-only → exit 3 with the refusal,
  release → exit 0 under `-CheckBuild`, not installed → exit 2; and `run-as` exiting 0 on a
  release-flagged dump is classified `debuggable`. CI: `workflow-lint` runs the self-test on every PR.
- **Not verified here.** No hardware run, and none is claimed: a testOnly build cannot be gate
  evidence by definition, and the phone's Knox admin state blocks admin rows (#181). Measuring the
  Phase 1 tamper rows on the release-signed APK is the run this change makes honest — it remains owed.
  Docs: `docs/QA/TESTING-STRATEGY.md` §3b and §5, `docs/TESTING.md` §5/§5f/§6, `AGENTS.md` §3.

### CI — the verified-gate workflow parses again, and workflow-lint now uses a real YAML parser
- My own edit to `verified-gate.yml` (accepting Kimi Code as a verifier) broke a comment line: the
  continuation lost its `#`, YAML parsed it as a key, and GitHub rejected the whole file. The run
  failed in 0 s with **no jobs** — the same signature as the incident that created `workflow-lint`
  (issue #37) — while `node scripts/check-workflows.mjs --strict` reported 0 errors, because that
  script matches text and never parses YAML.
- Fixed the comment. `workflow-lint` gains a real `yaml.safe_load` pass over every workflow file, so
  this class fails in a step that names the file and the line instead of in a jobless run.
- Consequence recorded: `verified-gate` was **not** made a required check while it was broken. It is
  fixed here; binding it is still the maintainer's step, and doing so will stall merges whenever both
  verifiers are idle (the gate's own documented risk).

### Process — a PR cannot merge until someone other than the author has verified its head (AGENTS.md §6.5)
- **Why.** On 2026-10-18/19 seven PRs merged on the author's own run, before or without the reviewer's
  points being addressed (#164, #168, #169, #171, #174, #180, #187); #169 then failed on hardware. §6.5
  already forbade this, but only in writing. The maintainer chose to enforce it with CI (2026-10-19).
- **What.** New `.github/workflows/verified-gate.yml`: on every PR to `main` the `verified-gate` check
  fails unless the PR carries `state:verified` and a comment signed `— Antigravity` or `— Claude`
  contains `Verified-sha: <sha>` matching the current head. A later push turns it red again. Read-only
  token; no labels are changed by CI.
- **Docs.** AGENTS.md §6.4 (enforcement table, branch protection is now available), §6.5 rule 6, §10
  `state:verified` row.
- **Limit.** All agents share one GitHub account, so the check cannot prove who verified; it makes a
  merge without verification a deliberate, visible act. It binds only once the maintainer makes
  `verified-gate` a required check with bypass disabled.
- **Tested.** `node scripts/check-workflows.mjs --strict`: 0 errors, 0 warnings. The step script was
  run locally against #195 and #191: no label → fail; label but no matching signed sha → fail; a
  signed `Verified-sha:` matching the head → pass.
### API — a recovery clears the authenticator, not the MFA policy (#183, security)
- **Why.** #180 merged with MFA recovery that defeated its own purpose. `/mfa/recover` wrote
  `mfaEnabled: false, mfaSecret: null` (`services/api/src/routes/auth.ts:495` at `675a118`), and
  `/login` asks for a TOTP only `if (parent.mfaEnabled)` (`:210`). So the first `POST /login` after
  a recovery, with the password alone, returned a **full session**; the purpose-scoped recovery
  token restricted nothing, and the account stayed password-only until someone chose to re-enrol.
  Claude's review called it "the first defeats the design" (issue #183, from the #180 review).
- **What.** The two flags now mean what they say: `mfaEnabled` is the account's second-factor
  **policy**, `mfaSecret` is the **bound factor**. `services/api/src/routes/auth.ts`:
  - `/mfa/recover` (`:524`) clears `mfaSecret` and **leaves `mfaEnabled` true** — the used code is
    still spent, the siblings are still deleted, every session is still revoked, the notice email is
    still sent.
  - `/login` (`:218`) with the correct password on `mfaEnabled && !mfaSecret` answers
    `401 {"error":"mfa_reenroll_required"}`: no access token, no refresh token, and deliberately
    **no recovery token** — minting one there (the shape issue #183 item 1 proposed) would let a
    stolen password bind a new authenticator two calls later. The 15-minute token from
    `/mfa/recover` (password + an unused code) is the only way back in.
  - `/mfa/enroll` and `/mfa/verify` accept that token while it is live and refuse it once the
    account holds a live batch again (`holdsLiveRecoveryBatch`) — `mfaEnabled` can no longer be
    read as "MFA is back", so the durable completion state is used, with the Redis `jti` delete as
    the primary boundary.
  - The parent app maps `mfa_reenroll_required` to its own message instead of "Invalid
    authentication code" (`apps/parent-app/lib/providers/auth_provider.dart`).
  - `docs/adr/0023-mfa-recovery.md` carries a dated amendment (decision 2's write list, decision
    3's guard); the accepted decision is not rewritten. `docs/SPEC.md` §3 and the `Parent` field
    comment in `prisma/schema.prisma` describe the two meanings.
- **Tests.** `services/api/test/mfa-recovery.test.ts` — five `#183:` cases plus the tightened
  post-recovery case: recovery then password-only login is refused with no session and no token;
  recovery token → enrol → verify → the new authenticator signs in; a normal MFA account still
  answers `401 mfa_required` then signs in; an account without MFA is unaffected; a recovery token
  is refused once a batch exists even if its Redis marker survived. The first three fail on
  `675a118` (`mfaEnabled` false after recovery; password-only login 200). Probe `O12`/`O13` assert
  the same against a live stack. `apps/parent-app/test/auth_provider_test.dart` covers the new
  message. **Author's runs, 2026-10-19:** `pnpm --filter @familyshield/api test` **33 files / 386
  tests passed** (exit 0; an earlier identical run on the same tree was killed by host memory
  pressure — `Exit status 3221225477` at 1.6 GB free — not by a test), `node scripts/qa-probe.mjs`
  against a spare-port instance **143 passed / 0 failed** (`O1`–`O13`), `node scripts/e2e.mjs`
  **69 passed / 0 failed**, `flutter test` **219 passed / 0 failed** and `flutter analyze`
  **No issues found**, probe
  integrity `+2 added, 0 removed`. The API at `127.0.0.1:3000` was not touched; the probe and e2e
  ran against `127.0.0.1:3419` from this branch. Database and Redis were restored afterwards
  (`cleanup-test-data.sql` → `OK: 1 family — demo family only`; 19 orphaned keys deleted, 3
  orphaned `mfa:lastcounter` keys removed). **⚠️ not verified here** by another agent.
- **Known cost (named, not hidden).** The 15-minute recovery token is now the only self-service
  path: a parent who loses the `/mfa/recover` response before `/mfa/verify` finishes is locked out
  until the support path (ADR-0023 Option B, still the maintainer's open decision). That is the
  price of "a stolen password alone cannot produce a session"; closing the usability half needs a
  product decision (a cooling-off, notified self-service re-enrolment), not this fix.
### Child agent — a blocked app can no longer hide in picture-in-picture or split screen (issue #175)
- **Why.** #171 made every block decision from `rootInActiveWindow` alone. A blocked app that is
  **visible but not the active window** was never judged: during bedtime a YouTube video in
  picture-in-picture over Home left the launcher (essential → ALLOW) as the only decision, and the
  video kept floating; the same trick worked in split screen beside the launcher or the dialer. This
  is a regression of the Phase 1 gate introduced by #171, not a new feature gap.
- **What.** `AccessibilityMonitorService` now takes one `WindowSnapshot` per event — the active
  package plus every `TYPE_APPLICATION` `AccessibilityWindowInfo`, including
  `isInPictureInPictureMode` — and runs the same `RuleRepository.evaluate` on
  `EssentialPackages.blockCandidates(active, visible)`. The lock's re-raise trigger
  (`LockEnforcementPolicy`) answers from the same snapshot, so a split sibling or a PiP window brings
  the overlay back. Both overlay activities declare `android:resizeableActivity="false"` and
  `android:supportsPictureInPicture="false"`: the system launches a non-resizable activity
  full-screen, which leaves split screen and keeps the overlay itself out of PiP.
- **Mechanism chosen, and why.** There is no public way for an accessibility service to close
  **another app's** PiP window (`Activity.setPictureInPictureParams` is the target's method, and
  `ActivityOptions.setLaunchWindowingMode` is hidden). The fallback from the issue is what was
  built: detect the multi-window state, re-raise and expand the overlay, bounded by
  `OverlayRetryBudget` — three raises per window-state signature, then one warning and no further
  activity starts until the state changes. A media pause through `AudioManager` focus is **not**
  added on a guess; ADR-0026 records that the hardware measurement decides it.
- **Leak fixed (same issue).** `rootInActiveWindow` and every window/root node obtained on this path
  are recycled; on API 26–32 an unrecycled `AccessibilityNodeInfo` leaked at up to ten walks a second.
- **Tests.** `MultiWindowCoverageTest` (10 JVM cases): launcher active with a blocked app in split →
  BLOCK; launcher active with a blocked app in PiP → BLOCK; a normal foreground app → BLOCK; a
  background app with no visible window → no overlay (the #171 `spay` case); our own overlay and the
  framework package are never candidates; the lock re-raises over split/PiP, does not when the
  overlay is the only window, and treats its own window in PiP as replaceable; the call surface stays
  reachable; the retry budget is bounded and resets on a state change. On the pre-fix tree the split,
  PiP, own-candidate, launcher-covered and own-PiP assertions fail (5 of 10); after the change all 10
  pass and both flavours' JVM suites stay green (raw output in the PR).
- **Hardware: not measured — blocked.** The Flip4 `R5CW116Y6GF` carries the stale Knox admin row
  from #181, so a run that needs a clean device-admin state cannot be trusted; the #175 row (YouTube
  in PiP over Home during bedtime, then YouTube in split beside the dialer, recording whether the
  overlay comes up **and** whether the PiP video keeps playing over it) is open on a clean phone.
  This entry does not claim the visual PiP result; if the PiP window stays above the overlay, the
  next step is decided from that measurement. See ADR-0026.
### Child Android — the block-rule exemption for the agent is an explicit package, not a namespace prefix (issue #192)
- **Why.** `enforcement/EssentialPackages.kt` exempted any package whose name started with
  `com.familyshield.`. Package names are global only by convention and the Full build is explicitly the
  sideloaded artefact, so a child could install `com.familyshield.notanapp` (or even name a package
  exactly `com.familyshield.`) and escape bedtime, routines, pause, blocklists, screen time and the
  block overlay. The prefix was meant as "our own components", which is a finite, enumerable set.
- **What.** `EssentialPackages` now exposes `OWN_PACKAGE = "com.familyshield.agent"` (the
  `applicationId` shared by the `play` and `full` flavours) as an explicit entry in `EXACT`, and
  `isEssential(name)` is exactly `name in EXACT` — no `startsWith` on our namespace. The KDoc
  enumerates the components that package legitimately fronts (`BlockActivity`, `LockActivity`,
  `RingActivity`, `SosActivity`, `TamperGuardActivity`, `PairingActivity`, `PairQrScanActivity`, the
  accessibility/location/VPN services and the OS-started receivers); Android has no per-component
  package, so one exact name is the complete allow-list. The dynamic rules are untouched: the current
  HOME handler and the OS-assigned dialer role remain genuine system-surface tests.
- **Tests.** `EssentialPackagesTest` gains a case pinning that `com.familyshield.notanapp`,
  `com.familyshield.agent.notanapp`, `com.familyshield.agent.test`, `com.familyshield.`,
  `com.familyshield` and `com.familyshieldx` are **not** essential through both `isEssential`
  overloads, while `OWN_PACKAGE` is; `RuleRepositoryEssentialExemptionTest` adds the decision-path
  assertions (bedtime/empty-cache answer BLOCK for `com.familyshield.notanapp`, ALLOW for the agent).
  The new assertions fail on the old predicate and pass after the change. The existing launcher,
  system-UI, dialer and OEM cases are unchanged and stay green.
- **Verification.** Author's run only (Kimi Code), on `origin/main@675a118`:
  `./gradlew testPlayDebugUnitTest testFullDebugUnitTest assemblePlayDebug --no-daemon` →
  **BUILD SUCCESSFUL in 17m 26s** (101 tasks); XML sums **Play 52 suites / 345 tests, 0 failures,
  0 errors, 0 skipped** and **Full 52 suites / 345 tests, 0 failures, 0 errors, 0 skipped**.
  `node scripts/check-merged-manifest-gate.mjs` → `2 result set(s) checked, all assertions ran and
  passed`, exit 0. Fail-before: the two new test methods were run against the old predicate and
  failed (`18 tests completed, 2 failed`) before the fix. **⚠️ not verified here:** the hardware row
  (install a stub package named `com.familyshield.<x>` and open it during bedtime) was **not run** —
  no device lease was taken in this lane; it stays open for the testing lane.

### Parent app — consent status per child, and a withdrawal flow that says what it really does (plan 3.7)
- **Why.** The API could withdraw consent (`POST /v1/family/children/:id/consent/revoke`,
  ADR-0008) and gated collection on it with 428, but no client could show a parent the record or
  perform the withdrawal. The record's real fields (`method`, `jurisdiction`, `grantedAt`,
  `expiresAt`, `thirdPartySharing`, `revokedAt`) were also invisible after withdrawal:
  `GET …/consent` returned only the *active* row, so a withdrawn record looked exactly like
  "never had one".
- **API (additive).** `GET /v1/family/children/:id/consent` now returns `records` — up to 20 rows,
  newest first, including revoked and expired ones — next to the existing
  `active`/`reason`/`jurisdiction`/`consent` fields (`services/api/src/routes/family.ts:231`).
  Nothing else changed on the server. New test in `services/api/test/consent.test.ts` failed
  before the change (`records` undefined: `AssertionError: Target cannot be null or undefined` at
  the length assertion) and passes after; the consent suite is **19/19**.
- **Screen.** `apps/parent-app/lib/features/children/consent_screen.dart` at `/child/:id/consent`,
  reached from a child-detail Overview tile. It shows method (translated label), jurisdiction,
  granted date, expiry (`No expiry` when null), third-party sharing, withdrawal date, earlier
  records, and a state chip: active / expiring within 14 days / expired / withdrawn / wrong
  region / no record. Expiry is derived from `expiresAt`, not invented.
- **Withdrawal is deliberately slow and honest.** A separate confirmation page states what stops —
  new location, app, web and chat collection; safety alerts (SOS, screen-time, blocked sites); rule
  enforcement on every device — and what keeps working (unlock and resume, per ADR-0008 §2c).
  It states what happens to data: **nothing is deleted or anonymised on withdrawal**; raw rows are
  removed by the retention job after `RETENTION_DAYS` (90 by default), usage summaries after
  `ROLLUP_RETENTION_DAYS` (365), and alerts are kept until erasure (`applyRetention` in
  `services/api/src/lib/usageModel.ts:220`; alerts are only removed by `eraseChildData`). Deleting
  the child is named as the separate immediate-erasure action. The parent must type the child's
  exact name before the button enables. The owner-only API (`requireOwner`) is respected in the UI;
  a 403 and a transport failure both say nothing changed. The result is read from the server's
  `count`: `count: 0` reports "There was no active consent record. Nothing changed." rather than a
  false success, and `devicesNotified` is shown.
- **Localization.** Every string is in both `app_en.arb` and `app_ar.arb`; the screen and the
  confirmation are rendered in Arabic RTL at 320×568.
- **Tests.** 14 widget/unit tests in `apps/parent-app/test/consent_test.dart` (state derivation,
  active / expiring / expired / revoked / no-record, non-owner, load retry, the typed-name gate,
  403 and transport failures, Arabic RTL) and two RTL cases in `test/localization_test.dart`.
  Author's run: `flutter test` **218 passed** (202 before the change + 16 new), `flutter analyze`
  clean; `services/api` `pnpm test` **382 passed** and `tsc --noEmit` exit 0. **⚠️ not verified
  here**: the run is the author's (Kimi Code); no independent verification and no merge sha yet.
  The live probe/e2e were not re-run from this branch: the API at `127.0.0.1:3000` predates it and
  must not be restarted from a feature branch, so neither would exercise this tree.

### Parent app — first-run wizard makes the parent half of 3.2 one guided path
- **Why.** Sign-in, family creation, adding a child and the pairing QR existed as separate screens
  reachable from different places. A non-engineer had no single path, and the 3.2 acceptance is
  "a non-engineer parent pairs in 5 minutes".
- **What.** `apps/parent-app/lib/features/onboarding/` adds Welcome → Sign in / Create account →
  Add your child → Pair their device → Done. `PairingQrScreen`
  (`lib/features/pairing/pair_qr_screen.dart`) gains a wizard mode with a short child-phone
  explanation and one primary action that checks `/v1/family/me` for a device **before** advancing;
  a click that finds no device says "Not paired yet" instead of moving on. The existing 600 s
  countdown and expiry copy are reused.
- **Resumable.** `lib/providers/onboarding_provider.dart` persists `onboarding_complete`,
  `onboarding_step`, `onboarding_child_id` and `pairing_pending` in `shared_preferences`, the same
  way `theme_mode`/`app_locale` are persisted. `lib/app.dart` steers every route back to the saved
  step; a session that expired mid-flow returns to sign-in, which cannot be skipped.
- **Skipping pairing is allowed but not silent.** "Set up later" completes the wizard and writes
  `pairing_pending`; the dashboard then shows a persistent **Finish setting up · Pair now** card
  (`dashboard_screen.dart`) that opens the normal pairing screen and clears itself once a device is
  reported. The Done step says "One step left" while pairing is pending — it never shows success for
  a partial setup.
- **Honest failures.** Wrong password and unreachable server are named in the wizard's sign-in step;
  child creation maps 428 (consent), 403 (owner only), 400/422 (invalid details) and transport
  failures to actionable copy; pair-code creation names a consent refusal instead of blaming the
  connection.
- **Localization.** All new copy is in `app_en.arb` and `app_ar.arb` with matching keys and
  placeholders; every step is rendered in Arabic RTL at 320×568.
- **Tests.** `apps/parent-app/test/onboarding_test.dart`, 18 widget tests: fresh install shows the
  wizard and a completed setup does not; direct setup routes cannot bypass sign-in; resume lands on
  the saved step; skip-pairing leaves the dashboard affordance; the full happy path advances only
  after a device; wrong password, unreachable server, consent refusal and QR expiry; Arabic + RTL at
  320×568 for each step; ARB key parity for the new strings. The existing suite's app-router tests
  now seed `onboarding_complete`, because their subject is the normal login/dashboard path.
- **Gates (author's run, this branch).** `flutter test` → **202 passed** (184 before this change);
  `flutter analyze` → **No issues found**. The API was not changed.
- **⚠️ Not verified here.** The acceptance itself — a timed five-minute first-run run by a
  non-engineer — was **not** run; TR-23's 21.2 s proxy measures the child typed path only. No merge
  sha and no independent verification yet.

### Android — protection removal is Knox-aware and the stale-admin dead end is named (issue #186)
- **Why.** Samsung activates device admin through Knox, and Knox keeps a persistent admin registry of
  its own. The in-app **Remove protection** path called AOSP `DevicePolicyManager.removeActiveAdmin`
  only (`apps/child-android/app/src/main/java/com/familyshield/agent/security/DeviceAdminManager.kt:90`
  before this change), which clears the AOSP view but not the Knox row. The next activation through
  the system sheet then failed with `IllegalArgumentException: Admin is already added` while
  `dumpsys device_policy` showed zero admins — the product became unusable for that component on
  Samsung (diagnosis in #181, measured on the Flip4).
- **Removal now follows the activation path.** `AdminRemovalPolicy` (pure, injected capability probe)
  tries Samsung's Knox admin API first when it exists and otherwise keeps AOSP
  `removeActiveAdmin`. `KnoxAdminCapability` reaches `com.samsung.android.knox.EnterpriseDeviceManager`
  by reflection only: it returns `null` on every non-Samsung device and on any lookup or invocation
  failure, so the class is not a build dependency and non-Samsung behaviour is byte-for-byte the old
  behaviour. If Knox claims success but AOSP still lists the admin, the policy falls back to AOSP.
  `DeviceAdminManager.removeAdmin()` logs the route it used.
- **The stale state is detected at enrolment.** After the system sheet returns with no active AOSP
  admin on a device that exposes Knox, the setup screen shows a specific explanation (`"Admin is
  already added"`, the Knox registry), the recovery step (Settings → Security and privacy → Device
  admin apps → deactivate OSRA), and a button that opens the device-admin settings screen. The same
  recovery hint appears on the status screen while protection is alert-only on a Knox device. The app
  does **not** try to clear another layer's registry entry itself.
- **Tests (author's).** 14 new JVM tests in
  `AdminRemovalPolicyTest` (Knox present → Knox; absent → AOSP; probe throws → AOSP; Knox throws,
  refuses, or leaves AOSP active → AOSP) and `AdminEnrolmentPolicyTest` (stale on sheet-returned +
  zero admins + Knox; not stale for active admin, device owner, pre-return, or non-Knox; the message
  names the cause, the Settings route and the factory-reset limit). Before the new classes the tests
  could not compile, so the behaviour had no passing test to preserve.
- **Gates (author's run, this branch).** `./gradlew testPlayDebugUnitTest testFullDebugUnitTest
  assemblePlayDebug --no-daemon` → `BUILD SUCCESSFUL`; **344 tests / 0 failures / 0 errors / 0 skipped**
  in each of `testPlayDebugUnitTest` and `testFullDebugUnitTest` (52 suites each).
  `node scripts/check-merged-manifest-gate.mjs` → `merged-manifest gate: 2 result set(s) checked, all
  assertions ran and passed`.
- **⚠️ Not verified on hardware.** Acceptance 1 of #186 — remove protection through the app, reinstall,
  activate through the sheet on the Flip4 — was **not** run: the phone still carries the unclearable
  stale Knox row from #181 and cannot activate this component through the UI. A read-only check on
  2026-10-19 confirmed the app is uninstalled and `dumpsys device_policy` lists no OSRA admin, so the
  phone was not disturbed. Acceptance 2 is covered by the JVM tests; acceptance 3 is covered only up
  to the pure classifier/message and needs a hardware pass once the row is cleared.

### Parent app — MFA screens make the #180 recovery codes reachable (ADR-0023, roadmap 3.3)
- **Settings › Two-step verification.** A new screen shows whether MFA is on, offers set-up or
  replacement of the authenticator, and is the only place a recovery-code batch can be requested.
  Enrolment calls `POST /v1/auth/mfa/enroll`, renders the returned `otpauthUrl` as a QR plus the
  secret for manual entry, and verifies the six-digit code with `POST /v1/auth/mfa/verify`. When the
  API answers `401 reauth_required` (a secret already exists) the screen asks for the password or a
  current authenticator code once and retries with that proof — the #139 rule is enforced by the
  server, not assumed by the client.
- **The codes are shown once, and the back action says so.** The verification response's ten codes
  are displayed on a dedicated screen with Copy-all and a mandatory "I have saved these codes"
  checkbox; leaving by the AppBar arrow or the system back gesture opens a warning that the batch
  cannot be shown again and that leaving means generating a new one. Regeneration asks for the #139
  proof before calling `POST /v1/auth/mfa/recovery-codes`, because the new batch invalidates the old.
- **Recovery entry on login.** "Lost your authenticator?" opens a form taking email + password + one
  unused code and calls `POST /v1/auth/mfa/recover`. On success the returned 15-minute
  `purpose:"mfa_recovery"` token is passed **only** to `/mfa/enroll` and `/mfa/verify` (a per-request
  Authorization override; it is never written to the `jwt` slot) and the app routes straight to
  re-enrolment. All failures show the single generic sentence the API's deliberate
  `401 invalid_recovery` supports — the screen does not claim to know which field was wrong.
- **Session honesty.** `/mfa/verify` revokes every session, so confirming the codes signs out locally
  and the login screen explains why rather than leaving a dead token in place.
- **Localization.** Every new string is in `app_en.arb` and `app_ar.arb`; the four new screens have
  Arabic + RTL widget tests at 320×568 and an MFA-prefixed ARB parity test (present, non-empty,
  placeholder-identical).
- **Evidence (author's).** `apps/parent-app`: `flutter test` **184 passed** (24 new in
  `test/mfa_screens_test.dart`), `flutter analyze` **No issues found**. The API was not modified.
  Independent verification and the merge sha are still owed.
- **Live-stack limitation (stated, not hidden).** A read-only contract check was attempted against the
  shared API at `http://127.0.0.1:3000`: it answers `404` on `/v1/auth/mfa/recovery-codes` and returns
  no `recoveryCodes` from `/v1/auth/mfa/verify`, so the running process predates #180. It was not
  restarted (standing instruction), and the field shapes the client parses are the ones the merged API
  tests and ADR-0023 assert. The disposable QA account created by the check was deleted with
  `cleanup-test-data.sql -v apply=1` (assertion `OK: 1 family — demo family only`), and no Redis keys
  for it remained.

### Docs + hardware — first-run pairing time measured as a proxy for 3.2's five-minute acceptance (TR-23, issue #181)
- **What was measured.** Three clean installs of the Full debug build from `main@df7c89e` on the Flip4
  reached the app's **"This device is paired"** screen in **21.4 / 21.1 / 21.2 s** wall clock from first
  launch — median **21.2 s**. The path was the typed one: launch → server URL → parent-issued six-digit
  code → PIN twice → **Activate device admin** → paired.
- **How much of it is the measurement.** Of the 21.2 s, **~14.6 s** is the harness itself (11.9 s of
  `uiautomator` dumps, 2.7 s of settle pauses) and ~0.65 s is machine typing, so the app-attributable path
  is **~7 s**. `POST /v1/devices/pair/claim` answered in **5.7 / 6.6 / 9.7 ms**, so no step waits on the
  network; the one ~1.6 s step (SAVE PIN) is PBKDF2 at 120 000 iterations on purpose.
- **This is a proxy, not a pass.** It models no reading, no human typing and no parent-app step, and it
  used the typed path rather than the QR. Roadmap 3.2's acceptance — a non-engineer parent pairs in five
  minutes — stays open and needs a human usability run.
- **Finding, filed not fixed (#181).** In **0 of 3** runs did device admin become active: the system
  `SecDeviceAdminAdd` sheet reports **Activate** as `clickable=false`, a tap dismisses the sheet, and the
  app ends on `⚠️ Protection: alert-only`. The flow measures the path to **paired**, not to "protection is
  on"; the app's onboarding cannot turn protection on through the UI on this phone (the shell
  `dpm set-active-admin` route, which earlier hardware runs used, still works).
- **New committed procedure.** `scripts/hardware/android-pairing-time.ps1` (Windows PowerShell 5.1,
  Full debug APK, app PIN supplied with `-Pin` at run time and never logged) and `docs/TESTING.md` §5h, which
  also records the two traps found: a sideloaded APK raises the Play Protect "send for a security check"
  sheet over the launcher (dismiss it before launching), and the One UI admin sheet's click target is the
  Activate row, not the button. Evidence:
  `C:\KARIM\tr-kimi\hw-2026-10-19\RESULTS-PAIRING-TIME.md`.
- **Diagnosed (#181, 2026-10-19).** The sheet is not inert and the app is not at fault: the tap runs
  `SecDeviceAdminAdd.addAndFinish()`, and Samsung's Knox registry throws
  `IllegalArgumentException: Admin is already added` because it still lists the component although
  `dumpsys device_policy` shows no active admin. The Knox row is created by an activation **through the
  sheet** and is not cleared by AOSP `dpm remove-active-admin` — the cleanup this repo documents for
  debug builds — so one shell cleanup after a UI activation poisons every later UI activation on that
  phone. A fresh component activates through the same sheet; a build without `testOnly` fails
  identically. Safe cleanup on Samsung is Settings → Device admin apps → Deactivate; `docs/TESTING.md`
  §5, §5h, §6 and §7 now carry the trap. The Flip4 used for this diagnosis still has a stale Knox row
  for `…FamilyShieldDeviceAdmin` that needs a maintainer decision (factory reset or equivalent); the
  app, its admin, the reverse and the pairing rows were cleaned up.
### API — one-time MFA recovery codes (ADR-0023 Option A, roadmap 3.3, `feat/23-mfa-recovery-codes`)
- **What a parent can now do.** With MFA on, the account has ten single-use recovery codes as well as
  the authenticator. `POST /v1/auth/mfa/verify` returns them (formatted `XXXX-XXXX-XXXX-XXXX`) in the
  same response that enables MFA; `POST /v1/auth/mfa/recovery-codes` issues a fresh batch, replacing
  the old one, and takes the same proof #139 requires to replace a secret (account password or a
  current TOTP). Lost the authenticator? `POST /v1/auth/mfa/recover` with `{email, password, code}`
  clears the second factor, spends the code, deletes the rest of the batch, revokes every session,
  emails a notice, and returns a 15-minute `purpose:"mfa_recovery"` token that re-enrols and
  re-verifies — and does nothing else.
- **Format and storage.** 16 Crockford base32 characters (80 bits, no `I`/`L`/`O`/`U`), normalised
  (uppercase, separators stripped, `I`/`L`→`1`, `O`→`0`) and stored only as SHA-256 in the new
  `ParentMfaRecoveryCode` table (`prisma/migrations/0017_parent_mfa_recovery_codes`, FK
  `onDelete: Cascade`, index `(parentId, usedAt)`). The plaintext exists in the issuing response and
  nowhere else: no route reads it back, and `sanitizeParent` strips the relation so `/family/me` and
  `/family/export` cannot carry a `codeHash` even if a future `include` adds one.
- **One-time use is transactionally enforced.** `updateMany({where:{id, usedAt:null}})` must return
  `count === 1`, so of two concurrent requests with the same code exactly one wins; the used row is
  kept as the record, its siblings are deleted. A wrong code writes nothing — the batch is intact
  afterwards. Failures are deliberately indistinguishable (`401 {"error":"invalid_recovery"}` for an
  unknown address, a wrong password, a wrong or spent code, and MFA-not-enabled), and the unknown-email
  path verifies a dummy argon2 hash so timing does not leak either.
- **The token is not a session and the #147 rule is untouched.** `requireJwt` still refuses every
  `purpose` token and still requires `role:"parent"`; the two enrolment routes use a separate
  `requireParentOrMfaRecovery` that accepts a recovery token only while `mfaEnabled === false` and only
  while Redis still holds `mfa:recovery:<jti>` → parentId (deleted on a successful verify; the store
  check fails closed). `/family/me`, `/logout-all` and `/mfa/recovery-codes` answer `401` to it.
- **Tests.** `services/api/test/mfa-recovery.test.ts` — 12 tests over a stateful code table: ten
  hashes and no plaintext in the rows; a valid code recovers once and clears the factor; replay and
  sibling codes refused; two concurrent claims → exactly one `200`; a wrong code does not consume the
  batch; the four no-oracle failures; the token's enrol/verify-only surface and its death once MFA is
  on; expired/unknown-jti/wrong-subject/wrong-purpose tokens refused; the #139 re-auth rule on
  `/mfa/recovery-codes`; nothing readable a second time; and login still needs the new authenticator
  (Option C stays rejected). `pnpm --filter @familyshield/api test` → **33 files, 381 passed**.
- **Probe.** `qa-probe.mjs` gained section O, **O1–O11** (`check()` count 109 → 120;
  `node scripts/check-probe-integrity.mjs --base origin/main` → *12 added, 0 removed, 0 demoted*). A
  live run against a spare-port instance of this branch (`API_BASE=http://127.0.0.1:3123`):
  **141 passed · 0 failed · 0 targets · 0 notes**, exit 0. The probe now waits out one 30-second TOTP
  window in section O — the replay guard refuses a second use of a counter, so a strictly newer code
  needs a newer window.
- **Migration.** Additive DDL only (`ParentMfaRecoveryCode`); an older API binary never selects it, so
  no backfill and no coordinated restart. **No backfill is possible for accounts that enabled MFA
  before this ships** — codes cannot be derived from the TOTP secret, so those parents get their first
  batch the next time they regenerate or re-verify while logged in. A parent already locked out is not
  helped by this change at all.
- **Not done here (deliberate).** The parent app has no MFA enrolment, code-display or recovery screen,
  so a normal user cannot reach any of this yet; the Flutter work (enrol, show codes once, "I saved
  them", recovery entry on login, forced re-enrolment) is a follow-up PR. The support-assisted path for
  the already-locked-out cohort (ADR-0023 Option B) stays a maintainer decision and was not built.
  ADR-0023's status is now `accepted (technical half, 2026-10-19; support path still open)`.
- **Verification state.** Author's own gates only. No independent record (`TR-*`) yet, no merge sha.

### Android — the child app scans the parent's pairing QR (roadmap 3.2, second half, PR #179)
- **What a parent does.** `PairingActivity` now has a **Scan QR code** action next to the typed form.
  `PairQrScanActivity` (`apps/child-android/app/src/main/java/com/familyshield/agent/setup/`) reads the
  parent's `osra://pair` QR with CameraX and the **bundled** ML Kit barcode model and returns the raw
  text; `PairQrPayload` (pure Kotlin, same process) applies the parent's Dart rules — version 1 only,
  exactly six digits, absolute `http(s)` host with no query or fragment — and refuses everything else
  with a stated reason. `PairingScanFlow` is the scan → review → confirm state machine, and
  `confirm()` is the **only** method that builds a `PairingRequest`.
- **A QR never pairs silently.** A successful scan fills the server and code fields (disabled, because
  the QR is authoritative), shows `Server: …` and `Code: ••••16`, and pairs only when the parent taps
  **Confirm and pair**. A refused payload returns to the typed form with its reason; a denied camera
  returns with an explanation that says why. The typed path keeps its old behaviour and wording.
- **The confirm step does not depend on the camera or on the activity staying alive.** It is plain state
  in `PairingActivity`; `onSaveInstanceState` stores the encoded v1 payload and `onCreate` re-validates
  it through the same parser, so a rotation keeps the review instead of silently dropping it.
- **Permission and policy.** `CAMERA` is declared in `src/main`, so both flavours carry it;
  `uses-feature android.hardware.camera required="false"` keeps a camera-less device installable. The
  Play allow-list carries `CAMERA` with its reason (`PlayManifestPolicy.ALLOWED_PERMISSIONS`),
  `PlayManifestPolicyTest` pins that entry, and `PlayMergedManifestTest` / `FullMergedManifestTest`
  assert it in the merged artefacts. The Play merge gained exactly one permission, `CAMERA`; CameraX
  and ML Kit brought none.
- **Dependencies, licences and size.** CameraX 1.3.4 (Apache-2.0; four AARs totalling **1,362,799
  bytes**) and `com.google.mlkit:barcode-scanning:17.3.0` (Google ML Kit Terms — **not** Apache-2.0;
  AAR **9,898,786 bytes**). The bundled model is deliberate: the first scan works offline, with no
  Play-services model download inside the five-minute flow. In the Play debug APK the ML Kit
  native/model payload is **21,103,960 bytes uncompressed** across four ABIs (the arm64
  `libbarhopper_v3.so` alone is 4,946,720 bytes; the three `.tflite` models total 880,888); an App
  Bundle splits the native libraries per ABI at release. Play debug APK: **36,857,551 bytes**; Full
  debug: **36,874,418 bytes**.
- **Tests.** `PairQrPayloadTest` (13 cases: valid http/https, leading zero, trailing slash, wrong and
  missing version, short/long/non-numeric/missing code, missing/non-http/query/fragment/malformed host,
  bare code, wrong scheme/authority/path, extra parameters, masking, encode round-trip) mirrors the
  Dart suite; `PairingScanFlowTest` (7) proves a scan alone builds no request, confirm builds it from
  the scanned values, a rejected scan cannot be confirmed, and cancel clears the review. Three manifest
  assertions were added (Play camera, Full camera, policy entry). **No Espresso test:** there is no
  `androidTest` source set, and `PairingActivity` is Hilt-injected, so an instrumentation test would
  need a Hilt test runner and new test dependencies; the confirm UI was therefore not exercised by an
  instrumentation test (the denial path was exercised on hardware).
- **Gate.** `./gradlew testPlayDebugUnitTest testFullDebugUnitTest assemblePlayDebug assembleFullDebug
  --no-daemon` → **BUILD SUCCESSFUL**, **330 tests / 0 failures / 0 errors / 0 skipped, 50 suites** in
  **each** flavour; `node scripts/check-merged-manifest-gate.mjs` → *2 result set(s) checked, all
  assertions ran and passed*, exit 0. Fail-before: pointing the Play gate at a copy of the merged
  manifest with `CAMERA` removed turned both `play merged manifest declares exactly the reviewed
  permission allow-list` and the new camera assertion red (`7 tests completed, 2 failed`, messages
  naming `missing=[android.permission.CAMERA]`).
- **Hardware (Flip4, `R5CW116Y6GF`, Full debug, lease held and released `Clean`).** Verified: the new
  **Scan QR code** button, the in-app rationale before the OS prompt, the OS camera prompt, the
  camera-ready status (`Camera ready. Point the phone …`), accessibility content descriptions on the
  preview, status and cancel action, and the **denial fallback** — "Don't allow" returned to the typed
  form with *"Camera permission was denied, so the QR scanner cannot start…"*. The typed path then
  paired end-to-end against the live API (`POST /v1/devices/pair/claim` reached the set-PIN screen);
  that test device was unpaired through the API and the app uninstalled. **Not verified here:** the
  rear camera was covered in the test position, so the scan → review → confirm steps were not aimed at
  a QR on the phone. That half remains open on the 3.2 row, together with the five-minute first-run
  test.

### Android — a debug build can be cleaned up without the app PIN, and only a debug build can (issue #170)
- **The defect.** `dpm remove-active-admin` answered `SecurityException: Attempt to remove non-test
  admin`, and with the admin still active `adb uninstall` answered
  `DELETE_FAILED_DEVICE_POLICY_MANAGER`. The only route off the phone was the app's "Remove protection"
  PIN gate, and since #164 the app PIN is deliberately not in the repository — so an agent without the
  credential could not finish a hardware run's cleanup (`AGENTS.md` §7/§9), which happened twice on
  2026-10-19.
- **The fix is one debug-only declaration.** `apps/child-android/app/src/debug/AndroidManifest.xml`
  merges `android:testOnly="true"` into the `<application>` of Play and Full **debug** builds. Android
  permits the shell to remove an admin whose package is `testOnly`; the test runner needs no PIN to end
  its run. Because the flag is a build-type overlay, `src/main` and `src/full` never see it: both
  **release** merges carry no `android:testOnly`.
- **The debug-only half is the acceptance, not a convenience.** `testOnly` is exactly what makes an APK
  replaceable without the parent's consent, so a release build that carried it would weaken the hard
  admin. `PlayMergedManifestTest` and `FullMergedManifestTest` now assert `testOnly="true"` in their
  **debug** merged manifest and its **absence** in their **release** merged manifest. The unit-test tasks
  depend on `process<Flavor>{Debug,Release}Manifest`, so a clean `./gradlew testPlayDebugUnitTest` builds
  the release artefacts the assertions read; if one is missing the test skips and
  `node scripts/check-merged-manifest-gate.mjs` fails on that skip rather than passing silently. The
  checker's expected-name list grew by the four new assertions. CI now builds `assembleFullRelease` as
  well as `assemblePlayRelease`.
- **Install note.** `adb install` refuses a `testOnly` APK without `-t`; a hardware run installs a debug
  build with `adb install -t -r …`. `scripts/hardware/android-signing-tr07.ps1` was updated accordingly,
  and `docs/TESTING.md` §5 shows the command. The release APK is unchanged and keeps the hard admin
  behind the app PIN.
- **Cleanup procedure** (`docs/TESTING.md` §5, §5a, §5f, §7; `AGENTS.md` §7): on a debug build,
  `adb shell dpm remove-active-admin --user 0
  com.familyshield.agent/.security.FamilyShieldDeviceAdmin` then `adb uninstall com.familyshield.agent`.
  On a release build the app PIN gate remains the path, and `dpm` still refuses — that difference is
  intended.
- **Gate:** `./gradlew testPlayDebugUnitTest testFullDebugUnitTest assemblePlayDebug assemblePlayRelease
  assembleFullRelease --no-daemon` → **BUILD SUCCESSFUL**, **307 tests / 0 failures / 0 errors / 48
  suites** in each debug flavour. `node scripts/check-merged-manifest-gate.mjs` → *2 result set(s)
  checked, all assertions ran and passed*, `exit=0`. Fail-before: moving the overlay to `src/release`
  turned **both** new assertions red (`6 tests completed, 2 failed`); with the release merged manifests
  removed the release assertion skips and the checker reports 6 skipped assertions and `exit=1`; and
  pointing `-Dosra.mergedManifest.playRelease` at a manifest that does carry `testOnly` fails the
  release assertion with the artefact path in the report. (That documented override now actually
  reaches the test JVM — Gradle does not forward arbitrary `-D` properties to the worker, so
  `app/build.gradle.kts` forwards the `osra.*` ones.)
- **Hardware verified on the Flip4** (`SM-F721B`, Android 16) against the Full debug APK
  (`app-full-debug.apk`, sha256 `ec41884a…`), phone lease held by Kimi Code and released `Clean`:
  `adb install -t` → `Success`; `dpm set-active-admin com.familyshield.agent/.security.FamilyShieldDeviceAdmin`
  → `Success`, and `dumpsys device_policy` reported `testOnlyAdmin=true`;
  `dpm remove-active-admin --user 0 …` → `Success: Admin removed …`, **exit 0**; `adb uninstall
  com.familyshield.agent` → `Success`, **exit 0**; `pm list packages | grep -i familyshield` empty. No
  app PIN was held or used. The release build was not installed on the phone; its half is asserted by
  the merged-manifest tests and the absence of `testOnly` in `assembleFullRelease` / `assemblePlayRelease`.
### Test infrastructure — the `parent-app` social test no longer depends on the wall clock (issue #176)
- **The defect.** `apps/parent-app/test/social_screen_test.dart` seeded its timeline from
  `DateTime.now()`. Between 00:00 and 00:40 local, the `now - 40 min` call crossed midnight, so the
  asserted *today* header did not exist (`Found 0 widgets with text "Monday, Oct 19, 2026"`); between
  00:00 and 02:00 local the `now - 26 h` call landed two days back, so `reveal(<yesterday>)` threw
  `Bad state: No element` at `:265`. The `parent-app` CI job was therefore red for two hours every day
  and took every open PR with it. Reproduced at **00:55Z on 2026-10-19**:
  `TZ=UTC flutter test test/social_screen_test.dart` → 7 passed, 1 failed with exactly that stack.
- **The fix (tests only, no product change).** The fixture pins
  `testNow = DateTime(2026, 10, 19, 12, 0)`; every default and timeline timestamp is derived from it,
  and the timeline is seeded from calendar fields (`today`, `yesterday`) rather than
  `base ± Duration`. The screen already groups by each event's local date, so it needed no clock seam.
  Two regression cases pin the fixture base at **00:00** and **23:59 local** and assert the same rows,
  mm:ss durations, 120-char preview cap and two day headers. On the old fixture the 00:00 case fails
  (`Monday, Oct 19, 2026` not found); the 23:59 case was green before and after and guards the other
  edge. The trap is recorded in `docs/TESTING.md` §6.
- **Gate:** `TZ=UTC flutter test` (inside the failing window) → all tests passed;
  `flutter analyze` → No issues found!.

### Android — the block decision is made from the window in front, not the accessibility event's package (issue #165, reopened)
- **The defect #169 did not cover.** On the Flip4 (Android 16, WM-Shell) the Home transition arrives
  as a `TYPE_WINDOW_STATE_CHANGED` event whose `packageName` is **`android`** — the framework — not
  `com.sec.android.app.launcher`. The essential set was right and its input was wrong:
  `com.sec.android.app.launcher` is in `EssentialPackages.EXACT`, but the decision was asked about
  `android`, answered BLOCK from bedtime, and `AppBlocker` raised the overlay over the launcher. The
  overlay's subtitle was the diagnosis (`android`). Measured on hardware after the #169 merge; raw
  output in `C:\KARIM\tr-kimi\hw-2026-10-19\RESULTS-165.md`.
- **The fix is about the input, not the set.** `EssentialPackages.foregroundPackage(eventPackage,
  windowPackage)` takes the event's package as a *hint* and the active window's package as the
  authority; `AccessibilityMonitorService` resolves it once per event (`rootInActiveWindow`, then the
  event source, then the event package) and uses that one value for the protection guard, the lock
  re-raise, the usage counter and the block decision. `android` alone resolves to `null` — no app can
  be named, so no overlay is raised — and `android` is deliberately **not** added to
  `EssentialPackages.EXACT`: the framework package fronts dialogs and shell surfaces, so exempting the
  name would exempt far more than Home.
- **A second instance of the same class, found on the test device.** The first build of this branch
  resolved the window only for window-state changes; a **background** app's content-change event then
  still decided from its own package — the overlay read `com.samsung.android.spay` while the launcher
  held focus, and pressing Home from that overlay put it back within a second. Every event now resolves
  the active window, so the overlay is raised only for the screen actually in front. (Cost: one
  `rootInActiveWindow` binder call per event, at the service's 100 ms throttle — at most ~10/s.)
- The decision gate stays pure and OS-aware through a predicate: `RuleRepository.decide` takes
  `essential: (String) -> Boolean` (default: the static set, for the JVM) and `RuleRepository.evaluate`
  passes `EssentialPackages.isEssential(it, packageFacts)`, so an OEM launcher the table has never seen
  is exempt because the OS says it holds HOME. `AppBlocker`'s existing `PackageFacts` guard stays as
  defence in depth, and the lock's exemption is unchanged — the lock still covers the launcher.
- Tests: `ForegroundEventBlockTest` (6 tests) pins the measured cases with the real `RuleEngine` and
  the real `decide` gate: a framework-package event whose window is the launcher is **ALLOW**; a
  genuinely blocked app is **BLOCK**; a background app's event is decided from the window; an OEM
  launcher resolved by the HOME role is ALLOW while the same name without the role is BLOCK; a
  framework event with no window association resolves to `null` (no overlay). It fails against the
  unfixed tree (`compilePlayDebugUnitTestKotlin`: `Unresolved reference: foregroundPackage`).
  Gate `./gradlew testPlayDebugUnitTest testFullDebugUnitTest assemblePlayDebug assembleFullDebug
  --no-daemon`: **303 tests / 0 failures / 0 errors, 48 suites, in each flavour**, `BUILD SUCCESSFUL`;
  `node scripts/check-merged-manifest-gate.mjs` → *2 result set(s) checked, all assertions ran and
  passed*.
- **Hardware verified on the Flip4** (`SM-F721B`, Android 16) with bedtime `21:00–07:00` active (device
  local 02:31) and the rule cache re-fetched after a relaunch, APK sha256 `0dbb9431…`: Home leaves
  `com.sec.android.app.launcher/…LauncherActivity` focused at **2 s and 6 s** (logcat:
  `event package android, window in front com.sec.android.app.launcher`);
  `am start -a android.intent.action.DIAL` leaves
  `com.samsung.android.dialer/DialtactsActivity` at 2 s and 6 s; `com.android.chrome` still shows the
  overlay at 2 s and 6 s with the subtitle `com.android.chrome`; Home from that overlay returns to the
  launcher at 2 s, 6 s and 14 s. Run log: `C:\KARIM\tr-kimi\hw-2026-10-19b\RESULTS-165B.md`.
  Lock-over-launcher was **not** re-measured on hardware (no `lock` was sent — the keyguard credential
  is the maintainer's); its JVM assertions are kept and pass.

### Android — bedtime no longer covers the launcher, the system UI or the dialer (issue #165)
- The app-block overlay (`BlockActivity`) now exempts the launcher, the system UI and the
  dialer/emergency surfaces for **every** rule, not just on the empty-cache path. Before this only the
  fail-closed branch (`RuleRepository.evaluate`) consulted the essential list, so an active bedtime
  rule — and equally an "everything except an allow-list" routine, school hours, pause-internet, the
  category blocklist, a screen-time limit or an explicit per-app block — answered BLOCK for the home
  screen and the overlay followed the launcher. The child could not press Home, reach the dialer, or
  read what would still work. Observed during TR-22 on the Flip4
  (`C:\KARIM\tr-kimi\hw-2026-10-19\RESULTS-ROW3.md`, observation 2: "This app is blocked by your parent
  — com.sec.android.app.launcher" after a relaunch) and recorded as a bug rather than fixed there.
- One set, one shared call-surface rule. `enforcement/EssentialPackages.kt` owns the list;
  `RuleRepository` (`decide`, called by `evaluate`) and `AppBlocker` read it, and its OS-aware form
  reuses the lock's call-surface exemption (`LockEnforcementPolicy.isExemptPackage`) instead of keeping
  a second call table. `RuleRepository.isEssentialApp` stays as the JVM-visible name and delegates.
- The overlay path is OS-aware as well: `AppBlocker` asks `PackageFacts`, so whatever currently holds
  the HOME role and any *system* dialer are exempt even when the table has never seen the OEM's name
  (`AndroidPackageFacts.homePackages()`, provided as one Hilt singleton and shared with the
  accessibility service, whose package-change receiver clears both caches). The narrow `<queries>` block
  gains the HOME intent — without it package visibility on API 30+ hides the launcher and the role
  lookup would silently return nothing; `PlayManifestPolicy.REQUIRED_QUERIES` and both merged-manifest
  gates now require it.
- Tightening in the same change: the fail-closed path exempted any name ending in `.dialer`/`.telecom`
  — the name-based bypass the review of #83 (F1) removed from the lock. A sideloaded `com.evil.dialer`
  is now blocked like any other app; a system dialer with that name stays exempt through `PackageFacts`.
- What still blocks: bedtime, allow-list routines, school hours, pause-internet, the category blocklist
  and screen-time limits block every app they name — only the essential set is exempt. The overlay's
  wording is unchanged for an app it covers; an exempt screen shows nothing.
- Tests: `RuleRepositoryEssentialExemptionTest` drives every policy that can raise `BlockActivity`
  through the real `RuleEngine` and the real `decide` gate (it fails against the unfixed gate — see the
  PR), `EssentialPackagesTest` pins the set, the name-spoof cases and the fact that the lock still
  covers the launcher, and `RuleRepositoryTest` keeps the `isEssentialApp` contract.
  Gate `./gradlew testPlayDebugUnitTest testFullDebugUnitTest assemblePlayDebug --no-daemon`:
  **297 tests / 0 failures / 0 errors in each flavour** (47 suites), `BUILD SUCCESSFUL in 1m 9s`,
  `app/build/outputs/apk/play/debug/app-play-debug.apk` built; the same new class fails 8/12 against
  the pre-fix gate (see the PR).
- **⚠️ Hardware not verified here.** The falsifiable check is in #165: with a bedtime rule active and
  an empty cache, Home leaves the launcher focused (`mCurrentFocus`) and
  `adb shell am start -a android.intent.action.DIAL` reaches the dialer. The phone was not taken for
  this change; that row stays open for a tester.
### Fix — the device-silence window is validated against the agent's reporting cadence (issue #166)
- **The collision.** The 5-minute floor for `DEVICE_SILENT_MINUTES` equalled the agent's stationary
  location ping (`apps/child-android/.../services/LocationService.kt:430`) and was shorter than one
  telemetry interval (`.../data/WorkScheduler.kt:48`, 15 minutes). At that floor a healthy stationary
  phone could be reported `device_silent` — a **critical** alert saying the child's phone went silent —
  depending on where the 5-minute job tick landed relative to the last report. TR-22 measured the
  alert correctly at a 5-minute window; the trap was for the next tester, and for any future per-family
  setting.
- **The rule (`services/api/src/jobs/deviceSilence.ts`).** The server now mirrors both cadences
  (`TELEMETRY_INTERVAL_MINUTES = 15`, `STATIONARY_PING_INTERVAL_MINUTES = 5`) and requires the window to
  leave **two telemetry intervals** of headroom: `SILENT_MIN_SAFE_MINUTES = 30`. A configured value
  below 30 is **clamped to 30** at boot with a warning naming the cadence
  (`resolveSilenceConfig` / `silenceConfigWarning`); a value that is not an integer ≥ 5 still falls back
  to 30, now with a warning too. **The default (30) is unchanged in behaviour**, and an unset or valid
  ≥ 30 value logs nothing.
- **Why clamp, not reject.** Refusing to start would take the whole API (all alerts) down over a tuning
  mistake; falling back to 30 would be the same clamp without saying so. The clamp is deterministic,
  keeps the safe default, and the warning makes the operator's value visible at boot.
- **Testability kept.** `DEVICE_SILENT_ALLOW_TIGHT=1` restores the old floor of 5 (never below it) and
  logs a `TEST ONLY` warning. It exists for the TR-22 hardware row, which needs a real elapsed short
  window; it is documented as test-only in `docs/TESTING.md` §5f and `.env.example`. The Android
  constants are **not** changed: the policy lives on the server, and slowing the phone's reports to
  satisfy a misconfigured alert threshold would trade a false alert for a later one.
- **Tests (`services/api/test/device-silence.test.ts`, +6 cases).** The tight 5 and 15 are clamped to
  30 with the warning text; 30 and 45 are accepted untouched; the override keeps 5 and is refused below
  it; invalid values fall back to 30; the startup path warns and logs the **effective** window. One
  test reads `WorkScheduler.kt` and `LocationService.kt` and asserts the mirrored constants and the
  `min = 2 × telemetry` relationship, so moving either cadence in the app fails the API suite.
- **Docs.** `docs/TESTING.md` §5f and the env table, `docs/QA/TESTING-STRATEGY.md` §3a (amendment under
  the accepted quote; the quote itself is untouched), TR-22's "how to re-run" and a superseding note
  under the TR-22 row, `services/api/.env.example`.
- **Verified here:** `pnpm --filter @familyshield/api test` 369/369; a branch API booted with
  `DEVICE_SILENT_MINUTES=5` logged the clamp warning (raw line in the PR) and started with
  `after=30m`; against that branch instance on `:3416`, `qa-probe` **130 passed · 0 failed · 0 targets**
  and `e2e` **69/69** with the Postgres row-count check (0 rows in 13 tables). **Not verified here:** a hardware re-run of TR-22 with the override — the row's
  existing PASS was measured before the clamp and its precondition now needs
  `DEVICE_SILENT_ALLOW_TIGHT=1`; that re-run is for a tester on the merged sha.

### Security hygiene — the test app PIN is no longer published (issue #151)
- The paired device's app PIN was written in clear text across `docs/TESTING.md`,
  `docs/QA/TEST-REQUESTS.md`, both verification ledgers and the probe's default. The literal is gone
  from `docs/` and `scripts/`; historical records that quoted it were redacted in place, because a
  credential in a dated record is still a credential.
- `scripts/hardware/android-bypass-probe.ps1` now requires `-Pin` and has no default, so a run cannot
  silently authenticate with a published value. Testers keep the PIN in a local, gitignored note.
- **Rotation is the maintainer's decision and is not done here:** changing it means re-pairing the
  physical test device once. The issue stays open until that happens.
- The unit test that hashes a PIN keeps its own literal — it is a test input for a hash function, not
  a credential for anything.

### QA — probe row 3 redefined to the accepted silence definition, and measured (`plan 1.9`, TR-22)
- **The decision is now in the documents, not only in a PR comment.** `docs/QA/TESTING-STRATEGY.md` §3a
  moved from "PROPOSED — not accepted" to **ACCEPTED — 2026-10-18, Claude (PR #127 comment 13:47:54Z;
  restated as an explicit acceptance on PR #154 at 18:46:39Z)**. The accepted row, verbatim: after
  `am force-stop`, wait one silence window (`DEVICE_SILENT_MINUTES`, default 30, floor 5) plus one
  5-minute tick, then require exactly one critical alert with category `tamper` / type `device_silent`
  for the device and `Device.status = "offline"`.
- **The probe measures it.** `scripts/hardware/android-bypass-probe.ps1` row 3 now reads the alert count
  and the device row from Postgres and waits the **real elapsed** window (new `-SilenceMinutes`, default
  30) plus one job tick; a missing alert is FAIL with the counts and `lastSeen` in the evidence. The old
  expectation — the agent back within 120 s — is measured and printed as a **NOTE** row that gates
  nothing, because Android keeps a force-stopped package stopped (`came back=False after 121 s`, TR-21).
  The script needs an API started with `JOBS_ENABLED=1`; the summary line now reports `NOTE` separately
  from `PASS`/`FAIL`/`NOT MEASURED` and the exit code is unchanged (`FAIL + NOT MEASURED`).
- **Measured** (TR-22, 2026-10-19, Flip4 `R5CW116Y6GF`, Full debug from `main@40f4f61`, API on `:3100`
  with `JOBS_ENABLED=1 DEVICE_SILENT_MINUTES=5`): row 1 **PASS** (`DELETE_FAILED_DEVICE_POLICY_MANAGER`);
  row 3 **PASS** — one critical `tamper`/`device_silent` alert **474 s** after the force-stop, inside
  the 630-s budget, and `Device.status` read `offline`; the 120-s note read *False after 122 s*. Evidence
  in `C:\KARIM\tr-kimi\hw-2026-10-19\` (not committed). **This is the author's run** — a tester re-run on
  the merged sha is still what makes it verification (`AGENTS.md` §1/§6.5).
- **Docs.** `docs/TESTING.md` §5f states the accepted row, the `JOBS_ENABLED=1`/`-SilenceMinutes`
  precondition and the run time (≈10.5 min at a 5-minute window, ≈35.5 min at the default); TR-21's row
  points at the replacement instead of implying the row is still open; `docs/ROADMAP.md` 0.6/1.9 and the
  Phase 1 summary carry the accepted definition.

### Security — `/token/refresh` cannot resurrect a session revoked mid-flight (#158)
- **The race.** `/token/refresh` accepted a refresh token, retired it, did a `Parent` DB round trip,
  and only then minted with `sv` read at that moment. A password reset / MFA enable / logout-all /
  theft response completing inside that window produced an access token carrying the
  **post-revocation** version (live) and a rotated refresh token in an index that had just been
  cleared — the session survived the revocation.
- **The fix (`services/api/src/routes/auth.ts:99,331-383`, `services/api/src/lib/sessions.ts:51`).**
  The refresh record now stores the sessions version at issue time (`sv`). `/token/refresh` reads
  `currentSessionVersion` **once, before retiring the token and before the DB round trip**, refuses
  `stored.sv < current` with `401 session_revoked`, and passes that same value into
  `signParentToken` (`opts.sv`) and the replacement record. A revocation that lands after the read
  leaves both returned credentials stale, so neither is usable.
- **Legacy records re-login.** A refresh record written before this change has no `sv`; it is refused
  (`401 session_revoked`) rather than treated as current. The legacy epoch is best-effort and
  8-day-lived, so it cannot establish the record's issuance reliably; one forced login per parent is
  the deliberate cost (ADR-0025 amendment).
- **Fail closed on revocation.** `invalidateSessionsBefore` no longer swallows a Redis error from the
  version `INCRBY`: logout-all / password reset / MFA enable / the theft response return 5xx and the
  client retries instead of reporting a revocation that never happened. The legacy epoch `SET` stays
  best-effort.
- **Tests.** `test/sessions-and-roles.test.ts` adds `#158: a revocation that lands during
  /token/refresh leaves neither returned credential live` (parks `parent.findUnique`, revokes while
  parked, then asserts the returned access token is refused by `isParentSessionLive` and
  `/logout-all` → 401 `session_revoked`, and the returned refresh token → 401 `session_revoked`) and
  `#158: a Redis failure during revocation fails the request (5xx)`. Both fail on `40f4f61` (the
  access token carried `sv:1` and the refresh succeeded; `invalidateSessionsBefore` resolved).
  `test/auth.test.ts`’s rotation test now also asserts that a detected theft kills the rotated
  token, which the old code failed to do.
- **Gates** (2026-10-19, author’s run in worktree `wt-158`): `pnpm --filter @familyshield/api test`
  → **363 passed**; probe integrity → 0 removed/demoted. `qa-probe` and `e2e` results are recorded in
  the PR body. ⚠️ These are the author’s runs (Kimi Code); no independent verification has been
  recorded yet.

### Parent app — English/Arabic localization with RTL (`plan 3.1`, first slice; follow-up #159)
- **Toolchain.** `flutter_localizations` + `intl 0.20.3`, a new `l10n.yaml`, `lib/l10n/app_en.arb`
  (template) and `lib/l10n/app_ar.arb`; generated `AppLocalizations` is checked in. `MaterialApp`
  (`lib/app.dart`) now carries `localizationsDelegates`, `supportedLocales` and a locale that
  follows the device. Settings → Appearance pins System / English / العربية, persisted under
  `shared_preferences` key `app_locale` with the same `StateNotifier` pattern as `theme_mode`
  (`lib/providers/locale_provider.dart`).
- **RTL is real.** The touched screens use `EdgeInsetsDirectional`/`AlignmentDirectional` and
  `start`/`end`; no screen hard-codes `TextDirection`. `AndroidManifest.xml` sets
  `android:supportsRtl="true"`. The child-detail app bar was compacted after the Arabic
  "تعديل القواعد" label overflowed 320 px by 12 px.
- **Translated surfaces.** Login, dashboard, child detail (including command labels/times and
  the embedded social tab), alerts and the alert-detail dialog, rules editor (all four tabs and
  dialogs), reports, usage history, pairing QR, Settings → Appearance, and the snippet-vault
  modal. API enum values (web-filter/alert categories, severities, command types/statuses) are
  mapped to labels instead of being shown raw. Dates use the app locale via
  `DateFormat(..., context.localeName)`.
- **Tests.** `test/localization_test.dart` adds 12 tests: each translated screen renders in
  Arabic + `Directionality(rtl)` at 320×568 with zero layout exceptions, the locale override
  survives a rebuilt `ProviderScope` (proving the preference round-trip), and the ARB gate fails
  on a missing or empty Arabic key or a placeholder mismatch.
- **Deliberately not translated.** The verifiable-parental-consent notice stays English pending a
  product/legal decision (`TODO(#159)`); family members, family map, search & web safety and
  digest preferences screens remain English; server-provided alert titles/bodies are displayed
  as supplied. Native-speaker review of Arabic screenshots — the row's acceptance — is still
  open (#159).
- **Gates** (2026-10-19, `apps/parent-app`): `flutter analyze` → **No issues found**;
  `flutter test` → **158 passed**. ⚠️ These are the author's runs (Kimi Code); no independent
  verification has been recorded yet.

### Android — no background location FGS without the background grant, and `locate_now` says why it failed (issue #132)
- **The #128 rule now covers every background start, not just boot.** `AccessibilityMonitorService.ensureLocationServiceRunning()`
  and `CommandDispatcher.locateNow()` requested `LocationService` on a fine/coarse check alone. Both
  run with no visible activity (an accessibility-service callback; a poll/FCM delivery), so on
  API 29+ that is a while-in-use grant, and Android 14+ refuses a location FGS created from the
  background without `ACCESS_BACKGROUND_LOCATION` — the `startForegroundService()` clock then ends in
  `ForegroundServiceDidNotStartInTimeException` (#128's failure) or `locate_now` dies silently with
  the parent told nothing. The rule moved to a shared `LocationStartPolicy`
  (`app/src/main/java/com/familyshield/agent/services/LocationStartPolicy.kt:1-61`): fine **or**
  coarse plus the background grant on API 29+; `BootStartPolicy` delegates to it, so there is one
  implementation and #128's boot tests still pin it.
- **Refusals are visible, not silent.** `AccessibilityMonitorService` logs
  `not starting LocationService: <reason>` once per distinct reason
  (`AccessibilityMonitorService.kt:92-131,201-224`). `CommandDispatcher` posts a `failed` command ack for
  the durable row (`POST /v1/devices/:id/commands/:commandId/ack`) with
  `detail.reason` = `background_location_missing` or `location_permission_missing`
  (`CommandDispatcher.kt:229-295,310-322`), so `/v1/devices/:id/commands/history` reads `failed` with
  the reason instead of `delivered` forever. The poll paths now pass `DeviceCommand.id`
  (`LocationService.kt:303-307`, `CommandPollWorker.kt:24-33`), and the ack surface is
  `ApiService.ackCommand` + `CommandAckDto` (`ApiService.kt:46-55`). A start the OS still refuses after
  the grants looked right is reported as `foreground_service_start_failed`.
- **`PairingActivity` is deliberately not gated.** Its start runs with the activity resumed, so the
  while-in-use grant is sufficient (the background rule applies to background starts). The
  distinction is written at the call site (`PairingActivity.kt:621-636`) and pinned by
  `LocationServiceStartSitesTest`, which scans the sources for `startForegroundService(… LocationService)`
  call sites and fails if a new one has neither a policy reference nor a foreground-site entry.
- **Tests.** 16 new tests in four classes: `LocationStartPolicyTest` (the rule),
  `AccessibilityMonitorLocationStartTest` and `CommandDispatcherLocateNowTest` (one per call site,
  `BootStartPolicyTest` style), and `LocationServiceStartSitesTest` (the call-site inventory).
  Fail-before at the pre-fix rule and unwired call sites:
  `16 tests completed, 6 failed` — the background cases in all three rule suites plus the inventory.
- **Gates** (2026-10-18, `apps/child-android`, JDK 17, `ANDROID_HOME`):
  `./gradlew testPlayDebugUnitTest testFullDebugUnitTest assemblePlayDebug assembleFullDebug --no-daemon`
  → `BUILD SUCCESSFUL` (12m 41s on the first full build, 3m 7s on the final incremental re-run),
  **267 tests / 0 failures / 0 errors in each flavour** (42 suites; the #128 baseline was 251, +16
  here), both debug APKs built (`app-play-debug.apk`, `app-full-debug.apk`). Fail-before in the same
  tree, with the pre-fix rule and unwired call sites: `16 tests completed, 6 failed`.
- **⚠️ Not verified on hardware in this PR.** No phone lease was taken: proving the `locate_now`
  failure path needs a device whose background location is revoked while the agent polls, and a
  run holds the lease. The rule and both call-site decisions are JVM-tested only; the row stays open
  until a leased run shows `failed` in the command history.
### Child agent — the merged manifest is what the gate reads, not the source (`plan 2.6`, ADR-0021)
- **The hole this closes.** `FlavorManifestTest` asserted `app/src/main/AndroidManifest.xml` and
  `app/src/full/AndroidManifest.xml` **as text**, and CI's Android step only ran `aapt2 dump badging`,
  which prints no permissions. Manifest merging happens after both, so a library that declares
  `READ_SMS`, `READ_CALL_LOG`, `QUERY_ALL_PACKAGES`, `READ_PHONE_STATE` or a notification listener is
  merged into the Play artefact with every gate still green — finding **F2** in Claude's #101 review of
  #100 (`docs/QA/DISCUSSION-LOG.md` §3, #101; recorded there as still open at `f099aa9`).
- **What changed.** `apps/child-android/app/src/test/java/com/familyshield/agent/manifest/`:
  `MergedManifest` parses the manifest AGP produced, `PlayManifestPolicy` holds ADR-0021's allow and deny
  lists as data, `PlayMergedManifestTest` and `FullMergedManifestTest` are the gate, and
  `PlayManifestPolicyTest` pins the checker itself against fixture manifests. The Play assertion is an
  **allow list** (the reviewed permission set — an unreviewed permission fails even when no deny rule
  names it) **plus a deny list** (each entry carries the decision that forbids it), not a single string
  match: the four Play methods are
  `play merged manifest declares exactly the reviewed permission allow-list`,
  `play merged manifest declares none of the Play-forbidden permissions`,
  `play merged manifest registers no notification, call-log or SMS component`, and
  `play merged manifest keeps isMonitoringTool and the three dialer queries`; the two Full methods are
  `full merged manifest keeps the capture permissions and the listener service` and
  `full merged manifest keeps isMonitoringTool and the dialer queries`.
- **Why the merged-manifest file.** It is the exact tree `aapt2` packages — `READ_PHONE_STATE` and
  `RECEIVE_SMS` are in the deny list for that reason — it is plain XML that a JVM unit test can parse
  without the SDK, and `app/build.gradle.kts` now makes both debug unit-test tasks depend on
  `process<Flavor>DebugManifest`, so a clean `./gradlew testPlayDebugUnitTest` produces it.
  `aapt2 dump xmltree` on the built APK was the alternative: it needs `assemble` plus build-tools on the
  test host and its dump format moves between build-tools versions, which is how a gate stops being run.
- **Fail-before, measured.** An AAR declaring `android.permission.READ_SMS` was added temporarily under
  `app/libs/` with `implementation(files("libs/inject-readsms.aar"))`: `testPlayDebugUnitTest` went red on
  `play merged manifest declares none of the Play-forbidden permissions` while `FlavorManifestTest`
  stayed green on the same tree — the hole, measured in one run. The AAR and the dependency line were
  removed before the commit; `PlayManifestPolicyTest` keeps the same injection as a permanent fixture.
- **CI.** `scripts/check-merged-manifest-gate.mjs` runs in the `child-android` job after the gradle step
  and fails the job when the gate skipped (its artefact was missing), failed, or lost a named assertion.
  The tests skip **only** when the merged manifest is absent — an IDE run — and say so loudly; CI never
  accepts that skip.
- **Gates** (2026-10-18, `apps/child-android`, JDK 17, `ANDROID_HOME=C:/KARIM/tools/android-sdk`):
  `./gradlew testPlayDebugUnitTest testFullDebugUnitTest assemblePlayDebug` — `BUILD SUCCESSFUL`, play
  **41 suites / 264 tests / 0 failures / 0 skipped** and full the same (264 was 251 at #131; the 13 new
  cases are 4 Play + 2 Full + 7 policy fixtures); `assemblePlayDebug` produced
  `app/build/outputs/apk/play/debug/app-play-debug.apk`; `node scripts/check-merged-manifest-gate.mjs` → both
  result sets, 4 + 2 assertions, 0 skipped. **Fail-before**, the same command with the injected AAR:
  `20 tests completed, 2 failed` — `play merged manifest declares exactly the reviewed permission
  allow-list` and `play merged manifest declares none of the Play-forbidden permissions` — while
  `FlavorManifestTest` was **7 tests / 0 failures** on the same tree. The merger's own report names the
  library (`manifest-merger-play-debug-report.txt`): `READ_SMS ADDED from [inject-readsms.aar]`, and
  `READ_PHONE_STATE`, `WRITE_EXTERNAL_STORAGE`, `READ_EXTERNAL_STORAGE` `IMPLIED … reason:
  com.example.readsmsfixture has a targetSdkVersion < 4` — four permissions from one dependency, none of
  them in any source manifest.
- **CI** (PR #157, `94ec897`): all seven checks pass; `child-android` **pass in 6m 21s** — the gradle step
  `BUILD SUCCESSFUL in 6m 15s` (168 tasks, cold cache) and the new step printed
  `merged-manifest gate: 2 result set(s) checked, all assertions ran and passed`. So the step is not only
  configured but executed, with both merged artefacts present.
- **Not verified here.** No independent re-run yet — every number above is the author's (`AGENTS.md`
  §6.5(2)); the tester should repeat the two gate commands on this branch. The gate is asserted on the
  **debug** merged manifests, which is the variant the unit-test tasks build — a release-only dependency
  (`releaseImplementation`) would merge into the release manifest and is not covered by a unit test, though
  no such dependency exists today.
### API — a token minted in the revocation second no longer survives the theft response (#117)
- **What changed.** Parent session revocation is a monotonic counter, not a wall-clock comparison.
  `signParentToken` stamps every access token with `sv` — the value of
  `auth:session-version:<parentId>` read at mint time — and `invalidateSessionsBefore` increments
  that counter (`services/api/src/lib/sessions.ts`). `isParentSessionLive` refuses `sv < current`,
  so a token minted in the same second as the revocation is dead, and a token minted after it works
  without waiting for the clock to tick. Password reset, MFA enable, logout-all, invite accept and
  the refresh-reuse/theft response all revoke through the same function. `/logout` still revokes its
  single `jti`.
- **Why a counter rather than `iat <= epoch`.** The inclusive-epoch variant (the issue's other
  option) still trusts each instance's clock: a revocation written by a host whose clock lags the
  minting host by ≥1 s leaves a token minted around the revocation alive, and it needs a mint-time
  `iat = max(now, epoch + 1)` adjustment. The counter lives in the shared Redis and compares
  integers, so clock skew and the number of API instances do not matter. Cost: one Redis `GET` per
  mint, one `INCRBY` per revocation, an `sv` claim, and a persistent `auth:session-version:<parentId>`
  key (it must not expire while a token minted above it is valid). Full reasoning and the rejected
  alternatives are in `docs/adr/0025-session-revocation-counter.md`.
- **Migration.** Tokens minted before this change have no `sv`; they are judged by the legacy
  `auth:invalid-before` epoch, now **inclusive** (`iat <= epoch`), and revocation still writes the
  epoch for them. That branch can be deleted 8 days after the last pre-#117 instance is gone. During
  a rolling deploy, a revocation served by a not-yet-upgraded instance writes only the epoch, which
  `sv` tokens ignore — deploy all instances (today: one) before relying on the guarantee.
  `services/api/scripts/cleanup-test-redis.mjs` now reaps an `auth:session-version:<parentId>` whose
  Parent row is gone; the key is deliberately TTL-less while the row exists.
- **Tests (they fail on `main@69d1575`).** Three new tests in
  `services/api/test/sessions-and-roles.test.ts` freeze the clock: a login at T then revocation at T
  is refused; a token minted at T-1 is refused while one at T+1 works; a legacy token (no `sv`) at T
  is refused. Against `origin/main`'s `sessions.ts` the same-second tests fail on the security assertion
  (`expected 200 to be 401`), not merely on the new claim. Probe F8 and N2 no longer wait for a second
  boundary — they now exercise the same-second property against a live stack.
- **Gates** (2026-10-18, on a spare-port instance `127.0.0.1:3017` running this branch):
  `pnpm --filter @familyshield/api test` **32 files / 361 tests passed**; `qa-probe`
  **130 passed · 0 failed · 0 x 429** (F8 and N2 pass, in the same second); `e2e` **69 passed,
  0 failed**; `check-probe-integrity.mjs --base origin/main` **109→109 checks, 0 removed/demoted**.
- **Not verified here.** No independent (Antigravity) re-run yet; running the raw gate output in the
  PR is the author's floor, not the merge evidence (AGENTS.md §6.5).

### Parent app — pairing code rendered as a QR (`plan 3.2`, first half)
- **What changed.** The child-detail device-card pair action (`Pair a device`, Overview tab) now
  opens a full-screen `PairingQrScreen` instead of a dialog. It still POSTs `/v1/devices/pair`, and
  shows the returned code three ways: a scannable QR, the six digits in large type, and a Copy
  action. A countdown runs to the server-supplied `expiresAt` — the route's `PAIR_TTL_SECONDS = 600`
  (`services/api/src/routes/devices.ts:69`) — and at zero the QR and digits are hidden, Copy is
  disabled, and Regenerate is the only way forward. Regenerate re-POSTs and replaces code and QR.
  The typed-code path is untouched: the parent still displays digits for the child agent, and the
  child app is unchanged.
- **Payload format (stable, versioned).** `osra://pair?v=1&code=<6 digits>&host=<API base URL>`, with
  `host` percent-encoded and taken from the parent app's runtime `api.raw.options.baseUrl` so a
  scanner learns the server as well as the code. `apps/parent-app/lib/features/pairing/pair_qr_payload.dart`
  is pure Dart, has a `decode`/`tryDecode` counterpart that rejects unknown versions and non-http(s)
  hosts, and is pinned by 7 unit tests including the exact encoded string. The format is documented
  in `docs/SPEC.md` §14.4.
- **Why `qr_flutter`.** Flutter has no built-in QR encoder and hand-rolling Reed–Solomon would be a
  security-sensitive liability for a first-run path. `qr_flutter` 4.1.0 (which depends on the pure-Dart
  `qr` package) is the maintained, widely used widget; it is the only new dependency.
- **Tests.** 12 new tests: 7 payload unit tests and 5 widget tests (QR renders with the documented
  payload, digits match, countdown reaches zero and disables the display, Regenerate POSTs again and
  changes the code, Copy writes the clipboard, and the action works at 320×568 with no overflow).
- **Gates** (2026-10-18, `apps/parent-app`): `flutter test` **146 passed** (was 134) and
  `flutter analyze` **no issues**.
- **Not verified here / still open.** The child agent has no QR scanner — `PairingActivity.kt` takes a
  typed six-digit code and a server URL — so the QR cannot be read yet; that scanner and the 5-minute
  non-engineer first-run test are the second half of row 3.2. No merge sha and no independent
  verification; the physical phone was deliberately not touched while another hardware run owns it.
### Docs — the two review promises of 2026-10-18 that never landed, and the gate commands that had drifted from CI

- **The two promises, by name.** The 2026-10-18 discussion log records them as carry-overs: the merge-ref
  trap row Kimi promised in the #96 thread (PR comment 07:33:17Z, "Recorded as worth a trap row in
  `docs/TESTING.md`") and the row-3 amendment Claude asked for in #127 (13:47:54Z, "record this as an
  amendment in `docs/QA/TESTING-STRATEGY.md`, next to the gate table"). The log's own carry-over check at
  `f099aa9` found neither; both are still absent at `4adc601`, which is where this branch starts.
- **`docs/TESTING.md` §6 — a trap row for "No checks reported".** A PR whose branch conflicts with its
  base has no `refs/pull/<n>/merge` ref, GitHub therefore creates no `pull_request` CI run at all, and the
  checks area is empty while every other PR is running normally. Empty reads as *pending* and the wait
  never ends. The row gives the diagnosis (`gh pr view <n> --json mergeable,mergeStateStatus` →
  `CONFLICTING`) and the exact fix (`git fetch origin && git merge origin/main`, resolve, push), dated
  2026-10-18 with #96 as the occurrence.
- **`docs/QA/TESTING-STRATEGY.md` §3a — probe row 3 as a *proposal*, not a gate change.** Row 3 demands
  the agent back within 120 s of `am force-stop`; on the Flip4 it measured `came back=False after 121 s`
  (TR-21, `main@7435592`) because Android keeps a force-stopped package stopped, so no code change can
  satisfy it. The section records the row's real intent ("the server notices a silent device"), the
  evidence that the alert now works — #124 (`4c41a07`: the watch matched `status=active`, which no writer
  produced; it matches `online` now, with a route-to-job test) and #150 (`4adc601`: probe `G22`/`G23` gate
  the live half, 130 passed / 0 failed) — and the proposed replacement assertion (one critical
  `tamper`/`device_silent` alert and `status=offline` within one silence window plus one tick). It states
  in its own heading that **row 3 remains FAIL until the maintainer or a reviewer accepts it**, and that
  nobody may edit the probe or record the row green on the strength of the proposal (`AGENTS.md` §4).
- **Command audit of the Flutter/API sections against the workflows.** Re-read `ci.yml` and
  `workflow-lint.yml` and fixed what would not work here: `VAULT_KEY=<same>` in §3 was wrong — the
  launcher's `VAULT_KEY` is its own 44-character base64 key, not the 64-character `INTERNAL_HMAC_SECRET`,
  and the old form produces `500 ERR_CRYPTO_INVALID_KEYLEN` on `/v1/social/scan` (the trap the same page
  already warned about) — verified without printing either secret; `API_BASE=http://127.0.0.1:3000` is now
  explicit because both scripts default to `http://localhost:3000` (`qa-probe.mjs:30`, `e2e.mjs:28`) and
  `localhost` can resolve to `::1` here; the health check uses `127.0.0.1` and shows the real body
  (`{"ok":true,"version":"0.1.0","db":"up","redis":"up"}`); the API suite now names the
  `prisma generate` step CI runs first; the Flutter row gained `flutter pub get` and the note that
  `C:\KARIM\tools\flutter\bin` is not on this host's `PATH`; the stale `e2e 50/50` became 69/69 as of
  #150 with the instruction to read `0 failed` rather than a count; the launcher's real location
  (`C:\KARIM\familyshield\dist\start-backend.bat`, outside the repo, absent from a fresh worktree) is
  named; and the CI table gained `probe-integrity` and the `check-docs-links.mjs` step, with both local
  commands listed.
- **Gates** (2026-10-18, docs-only change, so no code gate applies — `AGENTS.md` §6.5 "docs-only is no
  exception, but the check is proportional"): `node scripts/check-docs-links.mjs` → **0 broken link(s) out
  of 131 checked in 68 Markdown file(s)**, exit 0.
- **Deliberately not done.** No change to `services/api/scripts/qa-probe.mjs`,
  `scripts/hardware/android-bypass-probe.ps1` or any application code; row 3 is not marked passed and
  TR-21 keeps its FAIL; the issue #127 asked for (our own App-info page as a protected screen) is still
  not opened. No hardware run and no live gate — a hardware run holds the only phone.
- **Roadmap rows.** `docs/ROADMAP.md` gains Phase 0 row **0.6** for this debt, and row **1.9** now names
  the row-3 proposal and says it is unaccepted, so the Phase 1 gate row no longer reads as if force-stop
  self-recovery were still an open defect waiting for a fix.

### QA — `qa-probe` gates the three fixes #124 merged (audit findings 4–6)
- **What was missing.** #124 merged three security fixes with unit tests only; the probe had no live
  assertion for any of them, and the 2026-10-18 ledger records that gap under #124 ("no probe check
  added"). A unit test proves the handler's contract against mocks; it does not prove the deployed
  preHandler chain still composes the way the route declares.
- **Six new gating checks** in `services/api/scripts/qa-probe.mjs`, each with the assertion name on the
  `check(` line so `check-probe-integrity.mjs` can compare it:
  `G20` a device JWT posting telemetry for a **sibling device in the same family** is `403`
  (`{"error":"forbidden"}` — what `requireOwnDevice` returns); `G21` the same token posting for **its own**
  device is `202 {accepted:true}`; `G22` a real telemetry POST reads back as `status:"online"` with a fresh
  `lastSeen` — the value the silence watch matches, never `active`; `G23` every device status written in
  the run is inside the shared vocabulary (`online`/`offline`/`locked`/`sos`); `N6d` a co-parent admitted
  with only `alerts` gets `403 permission_required` (with `permission:"devices"`) on
  `POST /v1/devices/:id/push-token`; `N6e` the owner's `200` body contains neither `internalSecret` nor
  `pushToken`.
- **Why the silence *timing* is still a unit test.** The watch is an in-process 5-minute tick
  (`src/jobs/deviceSilence.ts`) with no HTTP trigger, and the probe deliberately connects only over HTTP
  (`API_BASE` + `INTERNAL_HMAC_SECRET`; it has no `DATABASE_URL`). Making a device silent in a gate would
  mean backdating `Device.lastSeen` in Postgres and then either waiting up to 5 minutes or calling the job
  in-process — which would also fire on unrelated rows of the shared stack. The probe therefore pins the
  half it can reach live (the status a writer produces) and the alert-per-episode half stays in
  `test/device-silence.test.ts`, which drives a real telemetry POST into `runDeviceSilenceCheck(now, env)`.
  `docs/TESTING.md` §6 records this as a trap so the next reader does not "fix" it by adding a database
  connection to the gate.
- **`requireOwnDevice` says `forbidden`, not `own_device_required`.** The probe asserts the merged error
  code rather than a nicer one; a distinct code would be a product change (and a probe rename) of its own.
- **Gates** (2026-10-18, shared `:3000` running `main@f099aa9`, probe and e2e ≥60 s apart):
  `pnpm --filter @familyshield/api test` **352 passed / 32 files**; `qa-probe` **130 passed · 0 failed**
  (was 124 — the six new rows) with `rate limit: 0 x 429`; `e2e` **69 passed · 0 failed** including the
  Postgres zero-rows count; `check-probe-integrity.mjs --base origin/main` **103 → 109 checks, 6 added,
  0 removed/demoted**. Cleanup: `cleanup-test-data.sql -v apply=1` leaves **1 family / 1 parent / 1 child /
  1 device** (demo only) and `cleanup-test-redis.mjs --apply` deleted **2 orphaned device keys**, 0 unknown
  persistent keys.
- **Not verified here:** no fail-before run of the *new probe rows* against the pre-#124 tree — that would
  need a second API instance built from `4c41a07^`, and the shared `:3000` must not be restarted. The
  fail-before evidence for the three fixes themselves is #124's own unit run (7 failed / 17 passed with
  the source stashed, per the ledger).
### API — a failed digest send no longer costs the family its period, and `DIGEST_HOUR` is documented as local (#93 review F1/F2/F3)

- **The two findings, verified on `main@f099aa9` before touching them.** F1:
  `services/api/src/jobs/digestScheduler.ts:119-120` logged a thrown `sendFamilyDigest` and left the
  `DigestSend` claim row in place, so every later tick's insert hit `P2002` and the family got no digest
  for that period — the refusal branch at `:113-117` deleted the claim, the two failure paths disagreed.
  F3: `services/api/.env.example:19` still said `DIGEST_HOUR_UTC=18` and `docs/TESTING.md:66` presented it
  as the switch, while `services/api/src/lib/digestSchedule.ts:108` had read it as the family's **local**
  hour since ADR-0017. F2 (permanent refusals retried every 15 minutes) was open in the same code and is
  fixed with F1.
- **F1/F2 — the claim now has a lifecycle** (ADR-0024). A transient failure — the provider refuses with
  `retryable: true`, or `send` **throws** — releases the claim (delete), so the next tick retries inside
  the same period. A permanent failure — `retryable: false`, e.g. an address the provider will never
  accept — keeps the row and sets the new `DigestSend.failedReason` (migration
  `0016_digest_send_failed_reason`), which is terminal for that period: the unique key skips every later
  tick and the row says why. The classification lives in the sender: `EmailResult`'s failure variant now
  carries `retryable`, and `ResendEmailSender` maps 408/429/5xx to retryable and every other 4xx to
  permanent, so the scheduler no longer infers failure class from an HTTP string.
- **Why a terminal state, not an attempt counter.** Transient retries are already bounded by the period
  boundary (one call per 15-minute tick until the local day or week rolls over), so a counter would buy a
  smaller number at the price of a re-claimable row — a state column plus an atomic `waiting → sending`
  update, which is a concurrency protocol and a new way to send twice. The terminal state buys the
  property that matters (a permanent refusal stops retrying) with one nullable column. The rejected
  alternatives and the costs (a misclassified permanent failure loses the day; a deterministic throw
  retries all evening; a retired row is log-visible only) are in `docs/adr/0024-digest-claim-failure-lifecycle.md`.
- **F3 — docs now say what the code does.** `.env.example` sets `DIGEST_HOUR=18` with the local-hour rule
  in the comment, and `docs/TESTING.md` names `DIGEST_HOUR` as the family's local hour. No rename was
  needed: the code already prefers `DIGEST_HOUR`; `DIGEST_HOUR_UTC` stays as the deprecated alias, read as
  a **local** hour, and `startDigestScheduler` now warns once at boot when it is the variable in use, so
  a deployment still on the old name learns the meaning changed instead of silently shifting its send
  hour. Historical mentions in `CHANGELOG.md` and the accepted ADR-0011 are left as they were written.
- **Tests that failed before.** Run against `origin/main`'s `digestScheduler.ts`, `email/index.ts` and
  `digestSchedule.ts` with this branch's tests: `5 failed | 25 passed (30)` — *a thrown send releases the
  claim and the next tick retries the same period* (`expected "spy" to be called … Number of calls: 0`),
  *a permanent provider refusal keeps the claim terminal and is not retried* (`expected "spy" to not be
  called at all, but actually been called 1 times`), the `EmailResult.retryable` classification test, the
  429 shape assertion, and the boot-warning test. The F3 clock test itself passes on `main` — the code
  was already correct; the defect was the documentation, and the test pins the local-hour reading so the
  docs cannot drift back.
- **Gates.** `pnpm --filter @familyshield/api test` **32 files / 358 passed, 0 failed** (352 on `main`;
  6 new) · `tsc --noEmit` exit 0 · `node scripts/check-probe-integrity.mjs --base origin/main`
  **check=103 both sides, 0 removed** · `check-docs-links` **0 broken / 129 in 68 files**.
- **Real Postgres, on a scratch database.** `familyshield_f93` was created, all 16 migrations applied
  (including `0016`), and a throwaway `runDigestsDue` script drove the four paths: thrown →
  `attempted 1, sent 0`, **0 rows**; 503 → `attempted 1, sent 0`, **0 rows**; 422 permanent →
  `attempted 1, sent 0`, **1 row with `failedReason: "HTTP 422 invalid to"`**; the next tick →
  `attempted 0, sent 0` with the provider called once in total; the next day → `attempted 1, sent 1`.
  The database was dropped afterwards (`SELECT count(*) … datname='familyshield_f93'` → `0`). The shared
  `familyshield` database and `:3000` were not touched: **`0016` must be applied before this code runs**
  (nullable and additive, so an older binary keeps working).
- **Not run here.** `qa-probe` and `e2e` — no route, probe check or response shape changed, and the
  shared `:3000` runs `main`, so it could not exercise this branch; the unit suite plus the real-Postgres
  run are the evidence for the claim paths.

### API — password-reset tokens are no longer bearer credentials (issue #146)
- **The hole.** `/reset/request` mints a 15-minute JWT with `purpose:"password_reset"` and no role, and
  `requireJwt` (`services/api/src/routes/auth.ts:204-216`) accepted any signature it could verify. An
  attacker with the mailbox could reset the password, mint a second reset token after the
  sessions-invalid-before epoch moved, present it to `/mfa/enroll` **with the password it had just set**,
  pass the #139 re-authentication branch, replace the TOTP secret, verify it, and log in with the
  attacker's authenticator. #139 was real but not sufficient: the reset token was a general bearer.
- **The fix.** `requireJwt` now accepts only a live **parent session** token: no `purpose` claim (or
  explicitly `"session"`), `role:"parent"`, and `isParentSessionLive`. A reset token is therefore
  refused (`401 unauthorized`) by `/mfa/enroll`, `/mfa/verify` and `/logout-all`; it remains valid only
  on `/reset/confirm`, the endpoint designed to consume it. The same purpose check is applied in
  `requireAuth`, `requireParent` and `requireFamily` (`services/api/src/middleware/requireFamily.ts`),
  so a purpose token is not accepted through a different bearer helper either; `isBearerSession` lives
  in `services/api/src/lib/sessions.ts`.
- **Reset semantics unchanged.** `/reset/confirm` still sets only the password and revokes sessions. For
  an MFA-enabled account the next login still needs the existing authenticator (`401 mfa_required`
  otherwise), and a user without MFA logs in with the new password. `GET`/`POST` clients that present a
  normal session token are unaffected; no shipped client uses a reset token as a bearer.
- **Tests that failed before.** `services/api/test/auth.test.ts` replays the chain: after
  `/reset/confirm`, a fresh reset-purpose token is `401` on `/mfa/enroll` both with and without the new
  password, and on `/logout-all`; the original TOTP still logs in and the attacker's does not. Run
  against `origin/main`'s code the two new tests failed `expected 200 to be 401`.
- **Gates.** `pnpm --filter @familyshield/api test` **352 passed**; `qa-probe` **124 passed · 0 failed**
  including new `G19`; `e2e` **68 passed · 0 failed**; `check-probe-integrity.mjs --base origin/main`
  **1 added, 0 removed**. Probe/e2e ran on a spare `:3100` instance of this branch; the shared `:3000`
  was not restarted. A live check also confirmed `/reset/confirm` still works for a user without MFA
  and for an MFA-enabled user (existing TOTP `200`, no code `401 mfa_required`, attacker TOTP `401`).

### Parent app — design system and dark theme (roadmap 3.8, `feat/3.8-design-system`)
- **One token layer.** `apps/parent-app/lib/theme/app_tokens.dart` defines the colour roles
  (`surface`, `surfaceVariant`, `primary`, `danger`/`warn`/`ok`, plus the legacy alert-severity and
  wellbeing-ring roles), the `AppSpace` spacing scale, `AppRadius`, `AppElevation` and `AppType` text
  styles. `apps/parent-app/lib/theme/app_theme.dart` turns those into `ThemeData` for both
  brightnesses and publishes the colours as an `AppTokens` theme extension, reached in a screen as
  `context.tokens`. Screens no longer name `Color(0x…)`, `Colors.*`, magic paddings or inline
  `TextStyle`s on the migrated surfaces.
- **Light and dark.** `FamilyShieldApp` (`apps/parent-app/lib/app.dart:61`) now passes `theme`,
  `darkTheme` and `themeMode`; the default `ThemeMode.system` follows
  `MediaQuery.platformBrightness`. Settings → Appearance (`/settings/appearance`, reached from the
  dashboard menu) pins System / Light / Dark; the choice is persisted with the existing
  `shared_preferences` package under key `theme_mode`, following the `ServerUrlNotifier` pattern
  (`apps/parent-app/lib/providers/theme_provider.dart`). No package was added.
- **Screens migrated without behaviour change.** Dashboard (`dashboard_screen.dart`), reports
  (`reports_screen.dart`), usage history (`usage_history_screen.dart`) and child detail
  (`child_detail_screen.dart`) now use the tokens for cards, padding/gaps, chart bars and labels,
  status dots, pills and inline text styles. Copy, testIDs and the 320×568 layout rules are unchanged.
  The alerts list keeps its pinned legacy severity palette, now expressed as severity tokens so dark
  mode can re-map it.
- **Tests:** 8 new tests in `apps/parent-app/test/design_system_test.dart` — the four migrated screens
  render in dark mode at 320×568 with no overflow, system mode follows a dark platform brightness, the
  Settings override survives a full widget-tree rebuild, and danger/warn/ok are checked at a computed
  ≥ 4.5:1 contrast against both surfaces in both themes. `flutter test` **134 passed** (126 before,
  all still green); `flutter analyze` clean. **⚠️ Author's run only** (Kimi Code) — no independent
  verifier has repeated the gates.
- **Not done here:** login, family, map, rules editor, social, content-safety and digest settings keep
  their existing spacing and colours; the token layer is available to them, but migrating each is its
  own layout-sensitive change. No hardware run and no visual/RTL review.
### Docs — ADR-0023 proposes the MFA recovery path (issue #136)
- **The gap.** Login requires a TOTP when MFA is on (`services/api/src/routes/auth.ts:174-180`), a
  password reset deliberately does not clear it (`:289-310`), and replacing the secret needs a session
  plus the password or a current code (`:218-254`). A parent who loses the authenticator and holds no
  live session has no supported way back in; and the reset-token path that reaches `/mfa/enroll` is
  the email-compromise takeover the design forbids. **Proved live on a disposable account:** reset
  with a chosen password → second reset token → `/mfa/enroll` with the new password → `/mfa/verify`
  with the attacker's TOTP → login `200`, i.e. mailbox control alone replaced MFA. The account and
  its Redis keys were removed afterwards (`OK: 1 family — demo family only`).
- **Proposal, not a change.** `docs/adr/0023-mfa-recovery.md` compares recovery codes at enrolment, a
  time-boxed support-assisted reset, and clearing MFA on email reset; it recommends one-time recovery
  codes (hashed, 80-bit, cleared on use) plus a support break-glass for the existing cohort that has no
  codes. Status **proposed** — the KCL lead ratifies; the support process is the maintainer's product
  decision. No code is written and #136 stays open.

### Parent app — daily screen-time trends and browsing history from the durable usage model (roadmap 3.5, `feat/3.5-usage-web-trends`)
- **One screen, both reads.** `UsageHistoryScreen` (`apps/parent-app/lib/features/reports/usage_history_screen.dart`)
  is reachable from the Reports app bar (`/child/:id/history`). Its 7/14/30-day selector drives both
  `GET /v1/reports/usage?childId&days=` and `GET /v1/reports/web?childId&days=&limit=&blocked=true`,
  so the trend and the browsing list always describe the same window.
- **Trend.** The chart is a row of plain `Container` bars (height proportional to the window's
  busiest day) — no new package; `fl_chart` is already a dependency for the top-apps summary but is not
  needed for a per-day bar series, and plain bars avoid 30 tick labels at 320 px. The honest total
  (`Total N min over M days`) and a day-by-day list (every returned day, including 0-minute days) are
  below the chart, so the numbers stay readable if the chart is not. `GET /v1/reports/usage` already
  fills a day with no rows as 0 (`usageSeries`), so the client draws exactly `series.length` bars and
  adds no padding; if a series shorter than requested ever arrives, it is shown as-is with `Only M of
  the N requested days were returned` rather than zero-filled.
- **Browsing history.** Each `WebVisit` row shows the domain, the local visit time and `Blocked` /
  `Allowed`; a `Blocked only` filter sends `blocked=true`, and a 20/50/100 limit control is the paging
  (the endpoint has no offset). When the API returns a full page the screen says the list is the latest
  N and raising the limit shows more.
- **States.** Both sections have an explicit loading placeholder that reserves the chart/list height,
  an empty state that distinguishes "no activity" from "no blocked sites", and an error line carrying
  the status/exception plus a `Try again` retry — an error never renders as an empty chart or a 0-minute
  day. All-zero windows show the empty state, not a chart of zeros.
- **Tests:** 14 widget tests in `apps/parent-app/test/usage_history_test.dart` — the selector refetches
  both endpoints with 7/14/30, a 30-day series renders 30 bars and its total/list, a short series is
  disclosed not padded, empty and error states for both sections, the blocked filter (`blocked=true`,
  allowed rows hidden), the limit control, the loading placeholders, the Reports entry point, and the
  320×568 layout with a 30-day series and a long domain. `flutter test` **126 passed**;
  `flutter analyze` clean. **⚠️ Author's run only** (Kimi Code) — no tester has repeated it, and the
  two endpoints were not re-run against a live stack from this branch (their API tests already cover
  the fields this screen reads).
- **Not done here:** no hardware/device run, no Arabic/RTL pass (roadmap 3.1), and no per-app split
  under each day even though the API returns `apps` — the list keeps to day totals for now.
### API — device enrollment is inside the `devices` permission, and `/register` no longer returns the raw row (issue #138)
- **Both credential-issuing routes now require `devices`.** `POST /v1/devices/register` and
  `POST /v1/devices/pair` compose `[requireParent, requirePermission("devices")]`
  (`services/api/src/routes/devices.ts:118,146`), matching `/:id/command`, `/:id/push-token` and
  `DELETE /:id`. Before, an invite with the default `permissions: []` could create a Device row and
  mint a pairing code that the unauthenticated `/pair/claim` exchanged for a device JWT **and a
  per-device HMAC secret**, while the same co-parent got `403 permission_required` on `command` and
  `unpair`. An owner passes implicitly; a co-parent or guardian needs `devices` in the invite. Reads
  are unchanged (never gated by permissions).
- **`/register` returns `sanitizeDevice(device)`** (`devices.ts:138`). The raw Prisma row carried the
  `internalSecret` column (the per-device HMAC key; null at enrollment, minted at claim) and any
  `pushToken` sent in the body. `/pair/claim` still returns the secret once — that is the credential
  handoff to the new device.
- **ADR:** `docs/adr/0014-signing-v2-sessions-and-family-roles.md` gains a dated amendment
  superseding the "(command, unpair)" enumeration in decision 5; `docs/SPEC.md` §14.1 names the
  permission on `/pair`.
- **Callers:** `e2e.mjs` and `qa-probe.mjs` call both routes with owner tokens (created by
  `/v1/auth/register`), so no change; the Android/iOS/Windows agents only call the unauthenticated
  `/pair/claim`. The parent app's pairing dialog surfaces the server's `403` for a signed-in
  co-parent/guardian without `devices`; owners and holders of `devices` are unaffected.
- **Tests:** `services/api` `pnpm test` → **349 passed / 0 failed** (3 new cases), including new
  cases in `test/devices.test.ts` and `test/pairing.test.ts` (co-parent with `devices` → 201 on both
  routes; without it → `403 {"error":"permission_required","permission":"devices"}`; register
  response has no `internalSecret`/`pushToken`). Fail-before on `origin/main`'s handlers (same tests,
  old `devices.ts`): **3 failed** — register deny `201` instead of `403`, register response still had
  `internalSecret`, pair deny `201` instead of `403`. Logs in the PR.
- **Probe:** three new gating checks — the setup register-response secret check and `N6b`/`N6c`,
  which prove both routes fail closed for an `alerts`-only co-parent. Probe integrity
  `--base origin/main`: `check=99 target=2 note=1` → `check=102 target=2 note=1` (**3 added, 0
  removed/demoted**). Live on a spare-port server (`:3100`, ≥60 s apart): probe **123 passed · 0
  failed · 0 targets · 0 notes**, e2e **69 passed / 0 failed**; database restored with
  `cleanup-test-data.sql -v apply=1` (1 family — demo only) and the Redis orphan sweep
  (`cleanup-test-redis.mjs --apply`: 2 orphaned device keys deleted, 0 persistent keys without an
  owner).

### Windows agent — the `0000` lock PIN is gone, and HTTPS inspection validates its upstream (`fix/desktop-pin-and-tls`, desktop audit findings 1–2)
- **No default parent PIN.** `RuleSyncService` and `ScreenTimeEnforcer` each had
  `Environment.GetEnvironmentVariable("DESKTOP_PARENT_PIN") ?? "0000"`, so any install without the
  env var locked with a PIN every child knows. Both defaults are removed. `ParentPinPolicy`
  (`apps/agent-desktop/Services/ParentPinPolicy.cs`) is the single definition of a usable PIN:
  4–8 ASCII digits, the legacy literal `0000` never counts, comparison is constant-time. The PIN is
  chosen in the pairing window (typed twice; `PairingDialog.cs`) and persisted in
  `agent.config.json` as `parentPin` — the same file and the same plaintext store that already holds
  the device JWT/HMAC secret (no new crypto scheme; audit WIN-11 on that store stays open).
- **Migration is one-shot.** `AgentConfig.Load` (`Services/AgentConfig.cs:76-101`) adopts
  `DESKTOP_PARENT_PIN` once, persists it, and then the stored PIN wins; a literal `0000` in the env
  var is treated as unset and is not written. An install that relied on the old default therefore
  starts with no PIN and says so. An identity supplied purely by env vars is not copied to disk by
  this migration — the env PIN stays effective for that process.
- **No PIN means no restriction, not a guessable one.** `lock`, `pause` and `wind_down`
  (`RuleSyncService.cs:228-292`, gate at `:328-345`) and bedtime/screen-time
  (`ScreenTimeEnforcer.cs:68-141`) refuse to arm without a configured PIN and log an error with the
  reason; `unlock`/`resume` still work so a stale overlay can always be cleared.
  `LockOverlay.ShowIfPinned` additionally refuses to render the overlay for a blank/`0000` PIN, so
  an accidental caller cannot create an unlockable-by-anyone lock. Startup prints the same warning
  (`Program.cs:32-38`).
- **HTTPS inspection now validates the upstream.** `HttpsInterception.TryConfigureDecryption`
  previously installed `e.IsValid = true` for every upstream certificate (accept-anything MITM).
  The default now requires no platform error and a chain built against the Windows trust store
  (chain, expiry, host name; revocation not fetched), leaving a failed certificate undecrypted
  rather than silently trusted. `FS_HTTPS_INSPECT_ALLOW_INSECURE=1` is the explicit, documented
  opt-out for a disposable test machine and logs a loud warning through the agent logger.
  `README.md` and `docs/test-guides/INSTALLATION-GUIDE.md` now state what inspection does and does
  not protect (pinned apps, WinHTTP/VPN bypass, and the local root CA as the trust anchor).
- **Tests:** +37 xunit cases (`ParentPinPolicyTests`, the PIN gate cases in
  `RuleSyncDispatchTests` and `ScreenTimePinGateTests`, the TLS policy cases in
  `HttpsInterceptionTests`, and seven `AgentConfigTests` migration cases) — **225/225 pass**
  (`dotnet test apps/agent-desktop/tests/FamilyShield.Agent.Tests`). Fail-before: with the two old
  behaviours restored in place (accept-all upstream; no-PIN default `0000`) the new policy cases
  fail (`SelfSignedUpstreamCertificateIsRejectedByDefault`, `BedtimeRefusesToArmWithoutAParentPin`,
  `LockRefusesToArmWithoutAParentPin`, `LegacyDefaultPinDoesNotArmTheLock`); details in the PR.
- **⚠️ Not verified here:** the pairing dialog was not driven on a real desktop session, and the
  TLS cases exercise the validation policy the proxy callback delegates to, not a live TLS
  handshake through the proxy. Both need a manual desktop row.
### API — audit findings 3–5: nonce store fails closed, MFA re-enrolment needs re-auth, family moves revoke the old scope (#139)
- **Finding 3 — a Redis outage no longer disables HMAC replay protection
  (`services/api/src/lib/internalAuth.ts:120-140`).** `claimNonce` used to `catch(() => "OK")`, so an
  unreachable replay store read as a successful claim and every byte-identical request was accepted.
  It now returns `claimed | replayed | unavailable`; production rejects with
  `401 { reason: "nonce_store_unavailable" }` and logs `[security] nonce store unreachable`, matching
  the fail-closed pattern in `lib/sessions.ts:62-67` and `routes/auth.ts:56-59`. Outside production the
  request stays permissive **and logs the degradation** (`replay protection disabled (dev/test only)`).
- **Finding 4 — replacing an enrolled TOTP secret requires re-authentication
  (`services/api/src/routes/auth.ts:221-260`).** `POST /v1/auth/mfa/enroll` overwrote `mfaSecret` on a
  bare session token, so a stolen 7-day access token could rebind the second factor. When the Parent
  row already has a secret, the body must now carry the account password (preferred; `argon2.verify`)
  or a current TOTP code (the existing `verifyTotpFresh` replay guard). A first enrolment — no secret
  yet — still works with the session token, so onboarding is unchanged; a failed re-auth is
  `401 { error: "reauth_required" }` and writes nothing.
  **Password reset still does not clear MFA** (that would let a reset bypass the second factor). The
  recovery path is deliberately out of scope here: a parent with an enrolled secret who has lost the
  authenticator cannot log in after a reset, because login still demands TOTP; clearing MFA requires
  a support-assisted identity check that this API does not implement yet. A parent who is still
  logged in can rotate the secret with their password through the new re-auth body.
- **Finding 5 — an invite accept kills the previous family's sessions, and family scoping reads the
  current row (`routes/invites.ts:82-92`, `middleware/requireFamily.ts:150-190`).** Accepting an invite
  moves `Parent.familyId` but used to leave the old 7-day access token carrying the old `familyId`
  claim, so it kept access to the previous family. Accept now calls the same
  `invalidateSessionsBefore(parent.id)` epoch that logout-all/password-reset/MFA-enable use; the fresh
  token is minted afterwards and stays live. `requireFamily` also stops trusting the token snapshot:
  for parent tokens it checks the session epoch and scopes the resource against the **current**
  `Parent.familyId`; a token whose claim disagrees with the row is `403 forbidden`, and a token older
  than the epoch is `401 session_revoked`. (Both layers are kept: the epoch also covers routes that
  compose `requireParent`, and the row check still protects family-scoped routes when Redis is
  unavailable.)
- **Tests:** `services/api` `pnpm test` → **346/346 passed** (4 new cases in
  `test/internal-signing.test.ts`, `test/auth.test.ts`, `test/invites.test.ts` and
  `test/sessions-and-roles.test.ts`). Fail-before evidence on `origin/main@265124f`: the same four
  cases fail (`nonce-store failure` returned `valid: true`; re-enrol returned `200` instead of `401`;
  no `auth:invalid-before` key was written; the old-family token read the old child with `200`).

### Android — a boot before location is granted no longer kills the agent (issue #128)
- **`BootReceiver` no longer requests `LocationService` unless the app can hold a location FGS.**
  The receiver called `ContextCompat.startForegroundService()` unconditionally; `LocationService`
  then declined to call `startForeground()` because the permission was missing and stopped itself —
  and the system still raised `android.app.ForegroundServiceDidNotStartInTimeException` in the
  receiver, taking the process down on the Flip4 (Android 16, `main@7435592`). The new guard is
  `BootReceiver.kt:53-65` calling a pure `BootStartPolicy` (`BootStartPolicy.kt:20-36`, the
  `LockEnforcementPolicy` pattern): fine/coarse location is required, and on API 29+ — a boot is a
  background context — so is `ACCESS_BACKGROUND_LOCATION`, the same definition of "Location (allow
  all the time)" that `GrantChecks` shows onboarding. With location denied the receiver logs one
  line and still schedules the workers, restores the web filter and re-raises a persisted lock.
- **Every boot step is isolated (`BootReceiver.kt:25-44,70-72`).** Location, scheduled work, the
  web filter and the lock re-raise each run in their own `runCatching`; a failure logs
  `BootReceiver: boot step failed: <step>` and the remaining steps still run. Before, only the VPN
  and lock steps were guarded — a throw from the workers or from `startForegroundService()` escaped
  `onReceive` and killed the reboot protection.
- **The manifest was already correct; a test now pins it.** `LocationService` declares
  `foregroundServiceType="location"` with `FOREGROUND_SERVICE_LOCATION`, `FilterVpnService`
  declares `specialUse` with `FOREGROUND_SERVICE_SPECIAL_USE`. `LocationService` reaches
  `startForeground()` as the first statement of `onStartCommand` (`onCreate` only fetches the fused
  client and creates the notification channel), so the OS deadline is not spent on setup.
- **Tests:** `BootStartPolicyTest` (4 cases) plus one new `FlavorManifestTest` case. The
  while-in-use-without-background case failed before the fix — fails-before run:
  `4 tests completed, 1 failed` at `BootStartPolicyTest.kt:25` — and passes now. Gate:
  `./gradlew testPlayDebugUnitTest testFullDebugUnitTest assembleFullDebug assemblePlayDebug`
  → `BUILD SUCCESSFUL in 5m 57s`, **251 tests / 0 failures in each flavour** (38 suites), both
  debug APKs built.
- **⚠️ Not verified on hardware in this PR:** the Flip4 was checked under the phone lease
  (`phone-claim.ps1`, released `Clean`, no app installed): `dumpsys window` reports
  `KeyguardServiceDelegate secure=true` and `dumpsys lock_settings` reports `CredentialType: PIN`,
  so `BOOT_COMPLETED` is not delivered to the agent until a human unlocks it after `adb reboot`.
  No reboot was run. The hardware row (issue #128 acceptance 1–2) stays open; the exact procedure
  is in `docs/TESTING.md` §5.
### QA — `e2e` stops on a 429 burst instead of manufacturing failures, and a missing `/me` envelope no longer truncates the run (issue #126)
- **`services/api/scripts/e2e.mjs` now speaks the same rate-limit contract as `qa-probe` (#112/#114).**
  `call()` counts every 429, retries once only when `Retry-After` is ≤ 3 s, and above 5 429s prints
  `ABORT: rate limited by the API (<n> x 429) - wait 60 s and re-run` and exits **2** — no `FAIL` row is
  recorded from a throttled response. Exit 1 keeps its meaning: a real assertion failed. Before this,
  the second gate of a sitting recorded the limiter as two product failures and the next call crashed.
- **A missing `/v1/family/me` envelope is one recorded failure and a printed summary.** The old
  `me.data.children.find(...)` dereference at `e2e.mjs:89` threw
  `TypeError: Cannot read properties of undefined (reading 'find')`; the run ended with no summary and,
  on Node 24/Windows, a libuv assertion (`exit 3221226505`). The envelope check records the failure and
  `stop()` prints the response body plus `=== E2E: n passed, m failed ===`, exiting 1.
- **Measured (2026-10-18, shared `:3000`, `main@7435592`):** `qa-probe` then `e2e` back-to-back → e2e
  printed `PASS  seeded parent login` and then
  `ABORT: rate limited by the API (1 x 429) - wait 60 s and re-run` (`Retry-After 11 s`), exit **2**,
  zero `FAIL` lines. After 60 s: **69 passed / 0 failed**. Probe integrity unchanged
  (`check=94 target=2 note=1`, 0 added, 0 removed/demoted).
- Tests: `test/e2e-rate-limit.test.ts` runs the real harness against an all-429 stub (both Retry-After
  branches), a stub that throttles each of the first six calls once (the > 5 counter), and a stub whose
  `/me` has no `children`; all four fail on `origin/main` and pass here. Full API suite:
  **339 passed / 0 failed**. Database restored with `cleanup-test-data.sql -v apply=1` after the runs.
### API — the WebSocket handshake is ticket-only; the legacy `?token=` bypass is gone (issue #120)
- **`GET /v1/ws` no longer accepts a JWT in the query string.** On `main` the `?token=<jwt>` branch
  (`services/api/src/realtime/gateway.ts:56-58`) verified the signature with `app.jwt.verify()` but never
  consulted the parent-session revocation state in `services/api/src/server.ts:82-84`, so a logged-out
  or theft-revoked parent token could still subscribe to `family:<familyId>:events`; the bearer token
  also leaked into proxy/access logs. A route-level `preValidation` now answers any handshake that
  carries `token` — or carries no ticket at all — with **401 `{"error":"ticket_required"}`**
  (`gateway.ts:54-63`). A missing/invalid/consumed ticket still closes the socket with **4001**.
  `POST /v1/ws-ticket` and the single-use ticket flow are unchanged.
- **Callers:** no client used the legacy path. `apps/parent-app/lib/providers/family_provider.dart:138,145`
  already mints and presents `?ticket=`; `services/api/scripts/e2e.mjs:154,172` and
  `services/api/scripts/qa-probe.mjs:713` do the same. Two documents still advertised `?token=` as
  accepted — `docs/test-guides/HANDOFF-FOR-TESTING.md:38` and
  `docs/SPEC-ADDENDUM-WORLD-CLASS.md:93` — and now state the 401. `README.md:152-153` claimed "JWTs
  never appear in URLs"; that was false before this change and is now literal, so it is kept and made
  explicit about the refused legacy query.
- **ADR:** `docs/adr/0022-websocket-ticket-only.md` records the decision, the rejected alternatives
  (repaired `?token=` path, deprecation window, 404) and its costs; it supersedes the "legacy `?token=`
  path is kept" clause of ADR-0004 (which is marked superseded in part).
- **Tests:** three new cases in `services/api/test/realtime.test.ts` (parent JWT, device JWT, no
  credentials) fail on `origin/main` with `404 !== 401` and pass here; the existing ticket/ready and
  single-use cases still pass. Full suite: **338 passed / 0 failed**.
- **Probe:** L6 (revoked parent token), L7 (device JWT), L7b (revoked device JWT), L8 (no ticket →
  JSON 401, not 404) and L9 (a fresh ticket still opens the stream) added;
  `check-probe-integrity.mjs --base origin/main` reports **5 added, 0 removed/demoted**. Live run on a
  branch instance (`127.0.0.1:3100`, shared Postgres/Redis): **120 passed · 0 failed · 0 targets · 0
  notes · 0 x 429**; `e2e.mjs` (run ≥60 s later): **69 passed / 0 failed**, with the Postgres erasure
  count executed (`DATABASE_URL` set).
- **Not verified on `:3000`:** the shared instance runs `main@7435592`, whose gateway still accepts
  `?token=`, so the gates above ran against a spare-port server started from this worktree. The test
  database was returned to the seeded demo state afterwards (`cleanup-test-data.sql -v apply=1`:
  1 family / 1 parent / 1 child / 1 device — demo family only).

### API — location/rules authorization: a JWT is not automatically a location writer, and a device reads only its own child
- **`POST /v1/location/ping` now admits exactly three callers** (`services/api/src/routes/location.ts:57-98`):
  a parent JWT (`role: "parent"` **and** a `familyId`), a device JWT (`role: "device"` with `deviceId` and
  `childId`, revocation check kept), or a valid HMAC request. Every other signature-valid JWT — the
  password-reset token (`purpose: "password_reset"`, no role), an unknown role, a parent without a
  `familyId` — is **401**. Previously `jwtVerify()` alone let those tokens through, and a token without a
  `familyId` skipped the handler's family comparison entirely.
- **The family check is unconditional for JWT callers** and a **parent-supplied `deviceId` must be a row
  of the named child** (`location.ts:203-221`). A device id from another child in the same family is
  **403 `device_mismatch`**; it used to write the ping onto that device's timeline after the FK check.
- **Device tokens are confined to their own child on reads.** `requireFamily` has a new
  `deviceAccess: "own-child"` mode (`services/api/src/middleware/requireFamily.ts:14-47,149-199`), used by
  `GET /v1/rules/:childId`, `/v1/location/:childId/latest`, `/history` and `/geofences/:childId`. A sibling
  child now answers **403 `cross_child_forbidden`**; parent tokens remain family-scoped (ADR-0002 §Decision,
  ADR-0003 §Decision). A revoked device's reads are still rejected by the app-wide revocation hook.
- **Tests:** new `test/location-auth.test.ts` (12 cases: reset/unknown-role/no-family tokens, cross-family
  parent, own-family parent write, foreign device id, missing device row, device own-child vs sibling on
  latest/history/geofences) and three device-scoping cases in `test/rules.test.ts`. All failed before the
  change; the full suite is **328 passed / 0 failed**. Probe: six new gating checks **G13–G18**, `115 passed · 0 failed`
  against a branch instance (`127.0.0.1:3100`, same Postgres/Redis); probe integrity reports **6 added, 0
  removed/demoted**. `e2e.mjs`: **69 passed / 0 failed** with `DATABASE_URL` set (the Postgres row-count
  check is no longer skipped).
- **Not verified on `:3000`:** the shared instance runs an older `main`, so the gates ran on a spare-port
  server started from this worktree. The database was returned to the seeded demo state afterwards
  (`cleanup-test-data.sql -v apply=1`).
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
- **Follow-up (this PR):** the deferred gate checks exist now — probe `G20`/`G21` (self-scoped device
  writes), `G22`/`G23` (status vocabulary), `N6d`/`N6e` (push-token permission and sanitized response);
  see the `QA — qa-probe gates the three fixes #124 merged` entry at the top of this file.
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
