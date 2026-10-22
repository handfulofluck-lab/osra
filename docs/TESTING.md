# Testing guide

Everything a contributor (human or agent) needs to run, interpret and trust the test story. For *why*
these gates exist, see `docs/adr/0005-adversarial-acceptance-gate.md` and
`docs/adr/0007-engineered-process-controls.md`.

## 1. The layers, and what each one is for

| Layer | Command | Covers | Fails when |
|---|---|---|---|
| API unit tests | `pnpm --filter @familyshield/api test` | Routes with mocked DB/Redis: auth, rules, devices, alerts, content, contracts | Logic/contract regressions |
| **Adversarial probe** (merge gate) | `node scripts/qa-probe.mjs` | Tries to **break** documented invariants against a live stack | Any invariant is violable |
| Live end-to-end | `node scripts/e2e.mjs` | The intended user journey (pair → rules → alerts → commands → export) | Wiring breaks on a real stack |
| Flutter | `cd apps/parent-app && flutter pub get && flutter analyze && flutter test` (needs `C:\KARIM\tools\flutter\bin` on `PATH` — §2) | Dashboard, rules editor, providers, light/dark design tokens and contrast, layout at 320×568, English/Arabic localization (ARB key parity + every translated screen in Arabic/RTL at 320×568) | UI/contract regressions, a missing Arabic string, an RTL overflow |
| Android JVM | `cd apps/child-android && ./gradlew testPlayDebugUnitTest testFullDebugUnitTest` (ADR-0016: two flavors, both must stay green) | Rule engine, counters, monitored apps, HMAC signing logic, flavor manifest difference, **the merged manifest** of both flavours (ADR-0021) | Agent logic regressions, a Play build that gained the notification permission or any Play-forbidden permission **through a dependency's manifest** |
| Windows (xunit) | `cd apps/agent-desktop && dotnet test tests/FamilyShield.Agent.Tests` | Proxy/process/screen-time/tamper logic | Agent logic regressions |
| AI engine | `cd services/ai-engine && pytest tests -q` | Classifier + API smoke (skips what is absent) | Classification/API regressions |
| iOS | `.github/workflows/ios-ci.yml` (macOS runner) | SwiftPM build + simulator build | Swift compile/behaviour regressions |
| **Hardware** (device) | section 5 | Crash-loop, FGS start, location upload, overlays | Anything the emulator cannot show |

A green unit suite is **not** evidence that an invariant holds — that is what the probe is for. A green
probe is **not** evidence that a feature works on a phone — that is what hardware verification is for.

**CI runs one step more than this table does** (`.github/workflows/ci.yml`, re-read against the gates on
2026-10-18), so a row below is the floor, not the gate:

| Suite | The step CI adds |
|---|---|
| API | `pnpm --filter @familyshield/api exec prisma generate` **before** `pnpm --filter @familyshield/api run build` and `run test` (`ci.yml:28-33`) — CI's own step comment records that `pnpm install` did not create the client (`ci.yml:28`), so the generate is a step, not an assumption. In a fresh worktree, generate first, every time |
| Flutter | the row's three commands are `ci.yml:47-49`; CI then runs `flutter build appbundle --release` and greps the AAB manifest for `android.permission.INTERNET` (`:68-79`) |
| Android JVM | the two test tasks plus `assemblePlayDebug assembleFullDebug assemblePlayRelease assembleFullRelease` in one invocation (`:123`), then **`node scripts/check-merged-manifest-gate.mjs`** (`:130` — fails the job if the merged-manifest gate skipped, failed or lost a named assertion), then `aapt2 dump badging` for `targetSdkVersion:'35'` and both network-security configs (`:131-139`). The gate reads `app/build/intermediates/merged_manifests/<flavor>Debug/**/AndroidManifest.xml` **and** `<flavor>Release/**/AndroidManifest.xml`; the test tasks depend on all four merges (`app/build.gradle.kts`). Since #170 the release half asserts that `android:testOnly` is absent |
| Windows | `dotnet test tests/FamilyShield.Agent.Tests --nologo` (`:150`) |
| AI engine | `pip install -r requirements-dev.txt` first (`:166`) |

A change is not done on the strength of a locally green suite whose build step was never exercised: the
release-assembly step is where a release-only failure lives.

## 2. Prerequisites (dev machine)

| Need | Where it lives here |
|---|---|
| Node + pnpm | this host runs **node 24.19.0** on `PATH` with pnpm 9.0.0 (`packageManager`); CI pins node 20 (`.github/workflows/ci.yml:22`), and `C:\KARIM\tools\node` holds 20.18.1 if you need that exact version |
| PostgreSQL | Windows service `OSRA-Postgres` (auto-start) or `C:\KARIM\start-pg.bat` |
| Redis | `C:\KARIM\tools\redis\redis-server.exe --port 6379` |
| JDK 17 + Android SDK | `C:\KARIM\tools\jdk-17`, `C:\KARIM\tools\android-sdk` (`ANDROID_HOME` **must** be set, or gradle fails with "SDK location not found") |
| Flutter | `C:\KARIM\tools\flutter\bin` (3.47.1) — **not** on this host's `PATH`: `export PATH="/c/KARIM/tools/flutter/bin:$PATH"` before any `flutter` command |
| .NET 8 SDK | `C:\KARIM\tools\dotnet` |
| Python 3.11+ | system python; AI tests need `services/ai-engine/requirements-dev.txt` |

Stack + secrets: the host launcher is `C:\KARIM\familyshield\dist\start-backend.bat` — **outside this
repo** and under a gitignored `dist\`, so a fresh worktree does not contain it. It starts
Postgres/Redis/API and seeds the demo family; the shipped template is
`docs/test-guides/start-backend.example.bat` (fix its `API=` path before using it). The secrets it sets
(`JWT_SECRET`, `INTERNAL_HMAC_SECRET`, `VAULT_KEY`) are required by the probe and e2e; never commit them,
and note that `VAULT_KEY` is **not** the HMAC secret (§3).

```bash
curl -s http://127.0.0.1:3000/health/deep   # {"ok":true,"version":"0.1.0","db":"up","redis":"up"}
                                            # use this, not /health, when apps misbehave: /health
                                            # does not touch dependencies
```

`127.0.0.1`, not `localhost`: on this host `localhost` resolves to `::1` first and a v4-only server then
looks dead (§6, the spare-port trap). The same rule applies to `API_BASE` in §3.

## 3. Running the gates

```bash
# from the repo root, once per checkout — CI runs this before its type-check and suite (ci.yml:28-33)
pnpm --filter @familyshield/api exec prisma generate

cd services/api
export DATABASE_URL=<launcher> INTERNAL_HMAC_SECRET=<launcher> VAULT_KEY=<launcher>
export API_BASE=http://127.0.0.1:3000                  # never localhost — see §6, the ::1 trap

node scripts/e2e.mjs        # 71 passed / 0 failed at 2026-10-21 — the count grows, read the 0
node scripts/qa-probe.mjs   # 151 passed / 0 failed / 0 targets at 2026-10-21 — any failure exits 1
```

`VAULT_KEY` is **its own** value, not the HMAC secret: the launcher sets a 44-character base64 key that
differs from the 64-character `INTERNAL_HMAC_SECRET` (measured on this host, 2026-10-18). The earlier
wording here said `VAULT_KEY=<same>`, which supplies the 64-character secret and fails two e2e checks with
`500 ERR_CRYPTO_INVALID_KEYLEN` — the harness trap described under the env table below.

`DATABASE_URL` is what makes `e2e.mjs`'s erasure step count the child's rows in Postgres itself (must be 0
in all 13 tables, ADR-0013) instead of printing a `NOTE` that the count was skipped — that skip is not a
pass. The probe does not need it, and deliberately has no database connection (§6).

### The AI evaluation harness (plan 4.2/4.3) — no stack, no key, seconds to run

```bash
cd services/ai-engine
export PYTHONIOENCODING=utf-8          # Windows consoles are cp1252 and raise on Arabic stdout
python -m pytest tests -q              # 54 passed at 2026-10-21 (20 before this harness existed)
python -m eval.banks                   # validate every template bank; must print the 7-row table
python -m eval.generate --check        # fail if eval/dataset.jsonl is stale against the banks
python -m eval.run_eval --scorer regex # publish-grade table; --write-md EVAL.md refreshes EVAL.md
python -m eval.run_eval --split test   # the held-out half of the template split (not yet run)
python -m eval.run_eval --scorer deepseek --limit-per-category 5   # plan 4.1, needs DEEPSEEK_API_KEY
```

Six things to know before reading a failure:

- **`--scorer deepseek`** is plan 4.1 and lives in `eval/deepseek_scorer.py`, evaluation only: the key comes from `DEEPSEEK_API_KEY`, results are cached by `(model, text)` in a gitignored file, and it is never imported by `model.py`. A missing key is one line, not a traceback. In CI it runs from `.github/workflows/ai-eval-deepseek.yml` on `workflow_dispatch` only — GitHub refuses to dispatch a workflow that is not on the default branch.
- **`--scorer regex` measures the rules layer alone** (`eval/run_eval.py:score_regex`), which is what
  runs when no checkpoint is shipped. `--scorer model` uses `MODEL_PATH`; `--scorer deepseek` refuses
  to run by design until plan 4.1 exists and the key is a repository secret.
- **A low recall is a published result, not a red gate.** Arabic is 0.00 across all seven categories
  (`EVAL.md` §The headline): the rules are English regular expressions, so nothing can match. CI runs
  the harness without a recall floor for exactly this reason — a floor of 0 cannot fail.
- **`test_regex_floor_catches_its_own_vocabulary` is the control.** It keeps the published numbers
  honest: the banks use paraphrase, so if that test fails the scorer itself broke, and if
  `test_regex_floor_is_blind_to_arabic` fails someone added Arabic rules and `EVAL.md` must be
  regenerated before the old numbers are quoted again.
- **The dataset is generated, not edited.** Change a bank, then `python -m eval.generate`, then commit
  the regenerated `dataset.jsonl` in the same change; a hand-edited row is a row the seed cannot
  reproduce. `eval/schema.md` carries the row format and the rule for adding a public or
  parent-reported source.
- **The split is per pattern, not per row.** A pattern is a template, its translation, its gender twin and
  a retelling of it (in another person, or with one detail changed) under one id, so none of them can sit on the other side of the
  split. `--split {all,dev,test}` filters before scoring; `all` is the published table, and `test` is held
  out from tuning — not from the prompt's author, who wrote every template (`EVAL.md` §The dev/test
  split). A row whose `provenance.split` has drifted from `eval/split.py::split_of(bank, pattern)` fails
  `test_committed_dataset_agrees_with_the_split_rule` — regenerate the dataset rather than editing it.

### Notification env (Phase 2a) — all optional

| Variable | Effect when set |
|---|---|
| `FCM_SERVICE_ACCOUNT_JSON` (JSON or base64) or `FCM_SERVICE_ACCOUNT_FILE` | Enables parent push via FCM HTTP v1 (Android, web, and iOS through Firebase). |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_ENV` | Enables direct APNs for native iOS tokens. |
| `PUSH_MIN_SEVERITY` (`info`\|`warning`\|`critical`, default `info`) | Severity floor; SOS and tamper always push. |
| `RESEND_API_KEY`, `EMAIL_FROM` | Enables real email. Without them emails are logged (dev) or a warning is logged (production); invites then echo `acceptToken` in dev only. |
| `APP_PUBLIC_URL` | Base URL used in reset/invite/digest links (default `http://localhost:3000`). |
| `DIGEST_HOUR` (default 18, the family's **local** hour per `Family.timezone`), `JOBS_ENABLED` (`0` disables the in-process scheduler) | Digest delivery schedule (ADR-0017). `DIGEST_HOUR_UTC` is the pre-ADR-0017 name: still read as a **local** hour, deprecated, and logged at boot when it is the one set. The e2e/probe stacks should set `JOBS_ENABLED=0`. |
| `ROLLUP_HOUR_UTC` (default 2), `RETENTION_DAYS` (default 90, floor 7), `LOCATION_RETENTION_DAYS` (default 30, floor 7, never above `RETENTION_DAYS`; ADR-0028 decision 5), `ROLLUP_RETENTION_DAYS` (default 365) | Phase 2c nightly usage rollup + retention (ADR-0013); same `JOBS_ENABLED` switch. `LocationPing` rows are deleted at the location window, every other raw table at `RETENTION_DAYS`. External cron: call `runUsageRollup()` from `src/jobs/usageRollup.ts`. |
| `DEVICE_SILENT_MINUTES` (default 30, safe minimum 30 = 2 × the agent's 15-minute telemetry cadence), `DEVICE_SILENT_ALLOW_TIGHT` (test only) | Device-silence watch (plan 1.9 finding): an `online` device unseen for longer raises one `tamper` / `device_silent` alert and is set `offline`; 5-min tick, Redis claim per episode; same `JOBS_ENABLED` switch. External cron: `runDeviceSilenceCheck()` from `src/jobs/deviceSilence.ts`. **Corrected 2026-10-18 (audit finding 4):** the job matched `active`, a status no writer produces, so it never fired; it matches `online` now and `test/device-silence.test.ts` drives a real telemetry POST into the job. **Since #166 the window is validated against the cadence:** `WorkScheduler.kt:48` reports telemetry every 15 minutes and `LocationService.kt:430` pings every 5 while stationary, so a value below 30 (two telemetry intervals) is raised to 30 at boot with a warning naming the cadence; the 5-minute floor survives only under `DEVICE_SILENT_ALLOW_TIGHT=1`, which logs a `TEST ONLY` warning and exists for the TR-22 hardware row. A unit test reads both Kotlin constants, so changing either cadence fails the API suite. |
| `INTERNAL_SIGNING_ALLOW_V1` (default **off** since 2026-10-17; `1` opts in), `INTERNAL_SERVICE_CALLERS` (default `ai-engine`) | ADR-0014 signing v2: legacy body-only signatures are refused (`401 legacy_signature_disabled`, probe check J7) unless the operator sets `1` for a rollout whose agents still sign v1 — the probe then reports target J7 so the state is visible; the global secret works only as a named service caller. Agents' clocks must be within 5 minutes of the server's or every signed call is `401 stale_timestamp`. |

Running `e2e.mjs` and `qa-probe.mjs` back-to-back within one minute from one host trips the API's
200 req/min rate limit. Since #112 and #126 the later gate stops with
`ABORT: rate limited by the API (n x 429) - wait 60 s and re-run` and exit **2** instead of recording
the throttled calls as failures — wait 60 s and re-run it alone; it is the limiter, not the product.

`VAULT_KEY` must be a base64-encoded 32-byte key (e.g. `head -c 32 /dev/urandom | base64`); any other
length makes `/v1/social/scan` return 500 `ERR_CRYPTO_INVALID_KEYLEN` and fails two e2e checks — a
harness trap, not a product bug.


**Reading the probe output.** It prints three severities, deliberately:

- **failures** — an invariant is broken. The gate exits non-zero; fix it before merging.
- **targets** — behaviour that needs a product decision before it can be asserted (replay protection `J2`,
  the global-secret fallback `J6`; consent revocation `J3 (+ J3b processing stop, J3c safe-direction, J3d agent commands)` is now resolved and enforced as a gate check). Non-gating, so the gate stays actionable; do **not**
  turn a target into a silent pass.
- **notes** — observations for the record (e.g. a route a parent can call that drains a device queue).

Rule: never make a check pass by loosening it. If a check is wrong, bring the evidence and fix the check
explicitly, in its own commit, with the reasoning in the PR.

## 4. CI (GitHub Actions)

| Workflow | Purpose |
|---|---|
| `ci.yml` | api · parent-app · child-android (`testPlayDebugUnitTest` + `testFullDebugUnitTest`, `assemblePlayDebug` + `assembleFullDebug` + `assemblePlayRelease` + `assembleFullRelease`) · agent-desktop · ai-engine · **`probe-integrity`** (`scripts/check-probe-integrity.mjs`, PRs only — the probe's assertion set may only be extended) |
| `ios-ci.yml` | The single iOS gate (SwiftPM build + `generic/platform=iOS Simulator`) |
| `workflow-lint.yml` | `scripts/check-workflows.mjs --strict` — a YAML file GitHub rejects means **zero jobs run**, so this is checked in its own file — and `scripts/check-docs-links.mjs` in the same job |
| `main-guard.yml` | Detects a commit on `main` that did not arrive through a pull request |

Local equivalents of the two lint gates (the workflow lint is also installed as a pre-push hook by
`scripts/install-git-hooks.sh`):

```bash
node scripts/check-workflows.mjs --strict
node scripts/check-docs-links.mjs          # 0 broken links — the only gate a docs-only PR must pass,
                                           # and the pre-push hook refuses a push that breaks one
```

## 5. Hardware verification (physical device)

### 5.0 One lease at a time (binding — `AGENTS.md` §9)

The handset is the maintainer's Samsung Galaxy Z Flip4, `adb` serial **R5CW116Y6GF**, attached to this
Windows host; every agent session here reaches the same phone. The lease recorded by
`scripts/hardware/phone-claim.ps1` is what authorises `adb`, and the human's need for the phone outranks
any lease. Why this exists: on 2026-10-17 a `lock` was left applied while the agent that sent it went
unreachable, and the Phase 1 gate (`TR-15`) needed the handset. A lease ends at a stated time, not when
its owner replies.

**Claim.** From the repo root, take an exclusive claim (two racers cannot both win) and record the
holder, purpose and expiry:

```powershell
.\scripts\hardware\phone-claim.ps1 -Action Claim -Owner "<agent>" -Purpose "TR-15: bypass probe"
```

Exit 0 means the phone is yours; exit 1 means it is held — `-Action Status` shows the holder and the time
left, and `-Action Wait -WaitMinutes 20` queues for it. Then post the same claim on the board
(`docs/QA/TEST-REQUESTS.md`, Messages), one line:

```text
DEVICE R5CW116Y6GF — <agent> — TR-15 — claimed until <HH:MM> UTC
```

The store is the lock; the board line is how a human or a remote agent sees it.

Default 60 minutes (5..240). Renew with `-Action Heartbeat -Owner "<agent>"` before the end time —
before a build and between long probe sections; nothing renews it in the background. At the end time the
claim expires and the next claimant takes it; expiry does not clean the phone. One lease, one agent;
build and analysis happen before the claim, not during it. The store is local to this Windows host, so
a remote agent must honour the board line.

**Pre-flight** — do this before the first command of every lease. Confirm the handset with the
`adb devices -l` line in the run block below; `$API`, `$DEV` and `$TOKEN` below are the test stack's
base URL, the paired device id and the test family's parent token.

```powershell
.\scripts\hardware\phone-claim.ps1 -Action Status   # HELD by you until HH:MM, or FREE/EXPIRED
```

```bash
adb shell dumpsys window | grep isKeyguardShowing   # true: the human unlocks it; see below
adb shell dumpsys activity activities | grep -i "topResumedActivity=.*LockActivity"   # no output = no overlay
adb reverse --list                                  # empty, or forwards you know are yours
adb shell pidof com.familyshield.agent              # a live process is the previous run's, not yours
curl -s "$API/v1/devices/$DEV/commands/history?limit=10" -H "Authorization: Bearer $TOKEN"
# no pending/delivered lock, pause, pause_internet or ring from the previous owner: the queue is
# durable and a lock waits 24 h (services/api/src/lib/deviceCommands.ts:41), so it can land on you
```

If that history shows a pending restriction, do not start: the warden settles it (relaunch the agent so
the queue drains, then `unlock`) or waits for `expiresAt`.

**Takeover.** An expired claim needs no permission: `-Action Claim` renames it aside, journals `EXPIRE`
and grants the phone to you. A live claim whose owner is unreachable is the warden's call —
`-Action Break -Owner "<warden>" -Purpose "recover the handset" -Reason "<why>" -Force`
(`AGENTS.md` §9.4). Either way the previous owner is not required to respond; apply the reset, allow up
to 90 s (the agent polls every 60 s; a `lock` took 59 s in TR-13, §5a), then verify:

```bash
curl -s -X POST "$API/v1/devices/$DEV/command" \
  -H "Authorization: Bearer $TOKEN" -H "content-type: application/json" \
  -d '{"command":"unlock"}'                    # {"published":true,"status":"pending",...}
adb shell dumpsys activity activities | grep -i "topResumedActivity=.*LockActivity"   # no output = overlay gone
```

`unlock` is safe-direction (no consent needed, `services/api/src/routes/devices.ts:49`) and asks the
system to dismiss the keyguard as well; it does not bypass a secure keyguard, and agents must never try
the human's PIN. If the keyguard is showing, the takeover stops there and waits for the human.

Last resort when the API or agent is unreachable: `adb shell am force-stop com.familyshield.agent`
removes the overlay with the process, but it also leaves the app in the stopped state — no receiver, job
or accessibility rebinding until it is launched again (measured by probe row 3, §5f). Record that you
did it; the next owner relaunches and re-grants.

**Release** is the last step of every run: clear `unlock` / `stop_ring` / `resume_internet` and verify,
then follow §7 (remove protection first if the admin is active, or `adb uninstall` fails — §5a). The
sanctioned removal is the app's **REMOVE PROTECTION (PARENT PIN)** action on the status screen — the
route a parent uses, and Knox-aware on Samsung since #186. `dpm remove-active-admin` is a last resort
only (§5): on a Samsung it strands the admin record. Then release the claim with the state you are
handing over:

```powershell
.\scripts\hardware\phone-claim.ps1 -Action Release -Owner "<agent>" -LeftState Clean -Note "app uninstalled, reverse removed"
```

`-LeftState` is mandatory and must be honest: `Clean`, `Locked` (the OSRA overlay is still up) or
`Unknown` (not checked). `Locked` prints the recovery step and is exactly the state that stranded the
phone once. A `lock` is never a way to reserve the phone.

Only a lease-holder does hardware verification, and only for an accepted request — the phone belongs to
a person, and the human may take it back at any time. `adb reverse` is the trick that makes it
repeatable: the device reaches the API on *this* machine without LAN or firewall changes.

```bash
export PATH="/c/KARIM/tools/android-sdk/platform-tools:$PATH"
adb devices -l                                  # confirm the intended device
adb reverse tcp:3000 tcp:3000                   # device can now reach http://127.0.0.1:3000
adb install -r apps/child-android/app/build/outputs/apk/release/app-release.apk
# A DEBUG build is `android:testOnly` since #170, so adb refuses it without -t:
#   adb install -t -r apps/child-android/app/build/outputs/apk/full/debug/app-full-debug.apk
# pair with a code minted by the API, then verify what the build claims:
adb logcat -c && adb shell monkey -p com.familyshield.agent -c android.intent.category.LAUNCHER 1
adb logcat -d | grep -c "FATAL EXCEPTION"                       # must be 0
adb shell dumpsys activity services com.familyshield.agent      # isForeground=true types=0x8 (location)
adb logcat -d | grep "location/ping"                            # <-- 201 Created is the proof of upload
psql -c 'SELECT count(*) FROM "LocationPing"'                   # a row means it really persisted
```

Cover at minimum: **first run with no location permission** (must not crash), **a reboot with location
denied** (the boot receiver must skip `LocationService`, log `location not granted`, and stay alive —
on a secure-keyguard phone this means after the first unlock), **a reboot with location granted**
(`LocationService` foreground within 60 s), **grant → service starts without relaunch**, **relaunch of
a paired app** (service resumes), **a ping that reaches the API**, and the specific claim the change
makes. Paste the raw evidence into the issue.

**Clean up afterwards — always** (`AGENTS.md` §7):

```bash
# CLEANUP ORDER (issues #202/#217). Remove protection through the app, never with dpm first:
# status screen → "Remove protection (parent PIN)". The removal is Knox-aware on Samsung since #186
# and is the route the app itself uses. The tester set this PIN at pairing; it is not the device
# keyguard PIN.
# THEN confirm no OSRA admin is left, and uninstall, and clear the reverse mapping:
adb shell dumpsys device_policy | grep -i familyshield    # no output = the admin is gone
adb uninstall com.familyshield.agent && adb reverse --remove-all
psql -h 127.0.0.1 -U familyshield -d familyshield -v apply=1 -f services/api/scripts/cleanup-test-data.sql
psql -c 'SELECT (SELECT count(*) FROM "Family"), (SELECT count(*) FROM "Child")'   # expect 1 / 1
node services/api/scripts/cleanup-test-redis.mjs            # dry run: lists orphaned per-device keys
node services/api/scripts/cleanup-test-redis.mjs --apply    # deletes only keys whose owner row is gone
```

`dpm remove-active-admin` is a **last resort**, not the debug-build procedure. On an AOSP phone it is
safe; on a **Samsung**, removing an admin that was activated through the system sheet with this command
leaves Knox's own admin record behind, and the next activation through the sheet then fails with
`Admin is already added` — measured again on the Flip4 in 2026-10-19 (#217, after #202 had renamed the
component). Use it only when the app itself cannot run, and record that you did:

```bash
# LAST RESORT ONLY — never on a Samsung whose admin came from the system sheet.
adb shell dpm remove-active-admin --user 0 com.familyshield.agent/.security.GuardianAdminReceiver
```

On a debug (`testOnly`) build this command still exits 0 without the app PIN (#170), but that
permission is not a reason to use it: `testOnly` is about replacing the package, and the trap above is
the same. TR-41 proves `testOnlyAdmin=true` from `dumpsys device_policy`; its cleanup no longer needs
the dpm command. If the command answers `SecurityException: Attempt to remove non-test admin`, the APK
was not the debug variant (or was built before #170): stop, say the build is wrong, and report it — a
release APK on the test phone is a finding, not a cleanup problem.

**Redis is part of the environment too** — `AGENTS.md` §7 says persistent (`TTL -1`) keys must be
removed or explained, and the SQL script cannot see them. `cleanup-test-redis.mjs` reaps only keys
whose owning row no longer exists; it **never** touches a `revoked:device:*` key for a device that
still exists, because that key is the control that makes an unpaired device's 10-year JWT get `401`
(issue #56). Any key it reports as kept, keep.

## 5a. Tamper protection on hardware (ADR-0010, plan 1.1/1.2)

With the agent paired and a parent PIN set (the pairing flow asks for it), activate Device Admin from the
status screen (or, for a test, `adb shell dpm set-active-admin com.familyshield.agent/.security.GuardianAdminReceiver`).
Then prove each line of the acceptance:

```bash
adb uninstall com.familyshield.agent          # must FAIL: Failure [DELETE_FAILED_DEVICE_POLICY_MANAGER]
adb shell am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:com.familyshield.agent
#   -> within ~1 s the OSRA "Protected" PIN screen is on top (uiautomator dump shows "Parent PIN");
#      the API log shows POST /v1/alerts/internal 201 (category tamper, type protection_screen_opened)
# Revoke admin the only way the OS allows (the shell refuses: `dpm remove-active-admin` throws
# "Attempt to remove non-test admin" on Android 14+): enter the PIN once on the guard to open a grace
# window, then Settings > Device admin apps > OSRA parental controls > Deactivate > OK
#   -> POST /v1/alerts/internal 201 (type device_admin_removed) within 60 s (3.3 s on the Flip4);
#      exactly ONE such row per deactivation (issue #225: a second, ~16 s later, is a regression
#      of the dedupe key); the status screen shows "alert-only" and `adb uninstall` works again
```

**Debug builds keep `testOnly`, but cleanup is still the app's PIN gate (issues #170, #217).** An
`assemblePlayDebug` / `assembleFullDebug` APK declares `android:testOnly="true"` in
`app/src/debug/AndroidManifest.xml`, which is what lets a test runner **replace** the package without a
signature match. It also lets `dpm remove-active-admin` remove a test admin without the app PIN — but
that is a last resort, not the procedure: on Samsung the shell call leaves Knox's registry row behind
and the next activation through the system sheet fails with `Admin is already added` (#202, #217).
Clean up the way a parent would:

```
status screen → Remove protection (parent PIN) → adb uninstall com.familyshield.agent
```

The PIN-gated path is Knox-aware since #186 and is the route the product itself uses. If the app
cannot be driven,
`adb shell dpm remove-active-admin --user 0 com.familyshield.agent/.security.GuardianAdminReceiver` is
allowed **only** off Samsung or for an admin set with `dpm set-active-admin`, and must be recorded.

`testOnly` is deliberately **debug-only**: it makes an APK replaceable without the parent's consent, so
the release manifests must not carry it. `PlayMergedManifestTest` / `FullMergedManifestTest` assert both
halves against the merged manifests (#170).

**Lock that holds (plan 1.3):** with the agent paired and "display over other apps" allowed, send a `lock`
(parent app, or `POST /v1/devices/:id/command {"command":"lock"}`); the overlay appears. Then
`adb shell input keyevent 3` (Home) and `adb shell input keyevent 187` (Recents) → the overlay is back on top
within ~1 s each time (`dumpsys activity activities | grep topResumed` → `LockActivity`). Then `adb reboot`,
wait for boot, unlock the phone → the overlay is on top again. `unlock` clears it and it stays cleared.
Measured on the Flip4 (TR-13): Home 2.1 s, Recents 1.2 s, Settings 2.1 s, Chrome 2.2 s; after the reboot the
overlay started 6.9 s after `BOOT_COMPLETED` (`logcat | grep "START u0 .*LockActivity"` shows
`BAL_ALLOW_SAW_PERMISSION` — the overlay permission is what lets the boot receiver raise it). On a phone with
a secure lock screen nothing of ours runs before the **first unlock** (Direct Boot), so "after boot" means
"after the first unlock"; do not queue the `unlock` command while the phone is still locked, or the poll
that catches up after boot clears the overlay in the same second it appears.

Re-pair from the status screen must show the PIN gate first; a wrong PIN five times returns to the launcher.
The Remove-protection button (PIN verified) deactivates admin **without** a tamper alert — that is the parent.

## 5c. Web filter / DNS sinkhole on hardware (ADR-0015, plan 1.4)

With the agent paired, tap **Set up web filter** on the status screen and accept the OS VPN dialog
(the key icon appears in the status bar; `adb shell dumpsys connectivity | grep -i vpn` lists the
tunnel; `dumpsys activity services FilterVpnService` shows it). Put a rule set on the child with
`webFilter.blockedDomains: ["example.com"]`, `safeSearchEnforced: true`, `youtubeRestrictedMode: "strict"`
(`PUT /v1/rules/:childId` with the parent token), then wait for the sync or restart the agent. Prove
each line:

```bash
adb shell ping -c1 www.example.com     # → "PING www.example.com (0.0.0.0)" — sunk (subdomain match)
adb shell ping -c1 www.google.com      # → a real address: SafeSearch is a CNAME to forcesafesearch.google.com
adb shell nslookup www.youtube.com     # (if present) → CNAME restrict.youtube.com
adb shell am start -a android.intent.action.VIEW -d https://www.example.com   # Chrome: "can't be reached"
adb shell am start -a android.intent.action.VIEW -d https://www.wikipedia.org  # loads normally
# pause-internet: POST /v1/devices/:id/command {"command":"pause_internet"} → the overlay appears AND
adb shell ping -c1 8.8.8.8             # → 100% packet loss (default route into the sinkhole)
adb shell ping -c1 www.wikipedia.org   # → "unknown host" (NXDOMAIN in pause mode)
# resume_internet → both work again; logcat shows "FilterVpn: tunnel up, mode=dns"
# tamper: Settings › Connections › More › VPN › OSRA › Disconnect → POST /v1/alerts/internal 201
#   (category tamper, type content_filter_disconnected) and the status row shows "Reconnect web filter"
```

`ping` through the shell uses the system resolver and so goes through the tunnel like any app; it is
the quickest proof. What a DNS sinkhole cannot do (Private DNS set to a host, an in-app DoH resolver,
IP literals) is listed in ADR-0015 and must not be reported as a bug.

## 5d. Guided onboarding on hardware (plan 1.6)

Fresh install, pair, set the PIN, then revoke one required grant at a time and confirm the agent
*notices*: the status screen must read `6 of 7 required grants done` and name the missing one, the
**Finish protection** button must open the checklist with that row red, its button must open the
screen that grants it, and coming back without granting must leave the row red. Quick toggles from the
shell: accessibility `settings put secure enabled_accessibility_services ""`; overlay `appops set
com.familyshield.agent SYSTEM_ALERT_WINDOW deny`; usage `appops set com.familyshield.agent
GET_USAGE_STATS deny`; background location `pm revoke com.familyshield.agent
android.permission.ACCESS_BACKGROUND_LOCATION`; Private DNS `settings put global private_dns_mode
hostname` + `settings put global private_dns_specifier dns.google` (restore with `off`). "Setup
complete" must not be reachable from a fresh pairing while any of the seven is missing.

## 5e. Ring and locate on hardware (plan 1.7)

Set the alarm stream to 0 (`adb shell media volume --stream 4 --set 0`), lock the screen, then
`POST /v1/devices/:id/command {"command":"ring"}`: the phone must ring at full alarm volume with the
red ring screen on over the lock screen; Back and the volume keys must not stop it; **Stop ringing
(parent PIN)** → wrong PIN stays, right PIN stops it and the alarm stream returns to 0. A second ring
and `{"command":"stop_ring"}` must stop it from the parent side. `{"command":"locate_now"}` must
produce a `LocationPing` whose `timestamp` is within 30 s of the command (`GET /v1/children/:id/location`
or the `LocationPing` table) — not the last cached fix.

## 5f. The ten-bypass probe (plan 1.9 — the Phase 1 gate)

`scripts/hardware/android-bypass-probe.ps1 -Serial <adb serial> -Port 3023 -StateFile <tr10-state.json> -Pin <app PIN>`
runs, against a paired phone with the PIN set and the test API reachable through `adb reverse`.
**`-Pin` is mandatory and has no default (since #151):** the app PIN is a credential for the paired
device, so it lives in your local, gitignored credentials note, never in this repository. Set it when
you pair, keep it out of commits, and rotate it if it has ever been pasted into a public place.

**Cleanup on a debug build is the app's PIN-gated removal too (issue #217).** The probe is run against a
debug APK, which is `android:testOnly`; that does **not** make `dpm remove-active-admin` the procedure.
End the run with the status screen's **REMOVE PROTECTION (PARENT PIN)** and then `adb uninstall
com.familyshield.agent` (§5). On Samsung the shell command strands Knox's admin record and blocks the
next sheet activation, so it is a last resort there, not a shortcut. The `-Pin` above is still needed
for the probe's in-app steps (the lock and ring gates). A **release** build has no `testOnly` and keeps
the same PIN-gated removal; that is the intended difference, not a bug.

**A testOnly/debuggable build cannot produce gate evidence (issue #178, `QA/TESTING-STRATEGY.md` §3b).**
Before the first row the probe reads `adb shell dumpsys package com.familyshield.agent` and inspects
`flags=[ … TEST_ONLY … DEBUGGABLE … ]`; `adb shell run-as com.familyshield.agent true` is the second
signal (a debug package exits 0, anything else prints `run-as: package not debuggable: …` and exits 1).
On a `test-only` or `debuggable` build the probe exits **3 without measuring a row**. A development run
may pass `-AllowTestBuild`: every row's evidence is then prefixed
`NOT EVIDENCE (testOnly/debuggable build)`, `bypass-probe.json` carries `gateEligible: false`, and the
summary says the run cannot open a gate — its exit 0 means the rows ran, never that the gate is open.
`-CheckBuild` prints the decision and exits (0 release, 3 blocked) without touching a row. The decision
is `scripts/hardware/classify-build.ps1`; its fixtures include real Flip4 `dumpsys` output and CI runs
`pwsh -NoProfile -File scripts/hardware/classify-build.ps1 -SelfTest` in `workflow-lint`.

`adb uninstall` · `pm clear` · force-stop (the server must notice the silent device) · accessibility off ·
overlay revoked · Private DNS provider · escaping a lock (Home / Recents / Settings) · going offline
to dodge or escape a lock · VPN disconnected in Settings · device admin deactivated from Settings.
Each row is a measured outcome (what the OS answered, the alert's latency counted in Postgres, what the
status screen says) and the table it prints goes into the PR verbatim. An eleventh row, **S1**, is a
safety check rather than a bypass: with the device locked, the emergency dialer must open and stay
on top (no call is placed) — a lock that covered it would be the one bug worse than every bypass. Two rows need a human tap on
One UI (the VPN and device-admin screens never idle for `uiautomator`); the script says when.

**Row 3 asserts the accepted definition (2026-10-18, `QA/TESTING-STRATEGY.md` §3a).** After
`am force-stop`, the row waits one silence window plus one 5-minute job tick, then requires exactly
**one** new critical `tamper` / `device_silent` alert for the device and `Device.status = "offline"`,
both read from Postgres (`scripts/hardware/android-bypass-probe.ps1`, row 3). The API under test must
run with `JOBS_ENABLED=1` for this row, and the row takes that long: a 5-minute window + one tick is a
~10.5-minute budget, the default 30-minute window is ~35.5 minutes.

**The window must match the server's effective value (since #166).** `DEVICE_SILENT_MINUTES` below 30
— the safe minimum, two 15-minute telemetry intervals — is clamped to 30 at boot, so a bare
`DEVICE_SILENT_MINUTES=5` no longer gives a 5-minute window and the probe would wait a 630-s budget for
an alert that arrives after ~35 minutes. For the short row, start the API with the test-only override
and pass the same number to the probe:

```bash
JOBS_ENABLED=1 DEVICE_SILENT_MINUTES=5 DEVICE_SILENT_ALLOW_TIGHT=1 pnpm exec tsx src/server.ts
# companion: -SilenceMinutes 5
```

The override logs `[device-silent] TEST ONLY …` at boot; it exists for this measurement and never for a
deployment. Without it, pass `-SilenceMinutes 30` (or omit it) and budget ~35.5 minutes. The reason the
safe minimum is two intervals, and not the 5-minute stationary ping, is that a missed telemetry tick
must not read as silence — the unit test `device-silence.test.ts` reads `WorkScheduler.kt:48` and
`LocationService.kt:430` and fails if either cadence moves.

The **old** expectation — the agent back within 120 s — is still
measured and printed as a **NOTE**, not a gate: Android keeps a force-stopped package in the stopped state
(`came back=False after 121 s` on the Flip4, TR-21, 2026-10-18), so no code change can meet it. A missing
alert is **FAIL** with the alert count, `Device.status` and `lastSeen` in the evidence; it is never a note.
First measurement under this definition: TR-22 (2026-10-19, `main@40f4f61`, window 5 minutes); the
re-run after #166 uses the override above.

**S1 has a precondition the other rows do not: the OS keyguard must be down.** `lock` is a real
`lockNow()` (ADR-0010), so on a phone with a secure lock the keyguard sits above `LockActivity` and above
anything `am start` launches; the dialer can never reach the front and the row would accuse
`LockActivity` whatever the policy does. The script tries `wm dismiss-keyguard` and a swipe, and if the
keyguard survives it reports the row as **NOT MEASURED** and exits non-zero (2026-10-17: it used to
report FAIL, which is how a measurement of the keyguard was mistaken for a measurement of the lock).
Unlock the phone with the lock overlay up and re-run.

**S2 (issue #87) is the mirror image: the keyguard must stay reachable while the overlay is up.** `lock`
raises a real keyguard; the probe then sends `pause` and requires `dumpsys window | grep mCurrentFocus`
**not** to be `LockActivity`. Reading focus from the window manager rather than the activity manager is the
whole point: "LockActivity is on top" and "the bouncer is reachable" can both be true in the activity
stack, and only `mCurrentFocus` says which one the owner sees. The row fails on the 2026-10-17 builds — a
`pause` over a live bouncer put `LockActivity` in front and the owner could not enter their PIN (recovery
needed `resume` from the server). No PIN is entered by the row; it only asserts that the bouncer holds
focus. It is a safety row, so it exits non-zero like the others.

## 5g. QR pairing on hardware (roadmap 3.2)

Prerequisite: a live stack and a pairing code (`POST /v1/devices/pair` with the parent token), then the
payload `osra://pair?v=1&code=<6 digits>&host=<API base>` rendered as a QR on a second screen. The real
source is the parent app's `PairingQrScreen`; a generated PNG is a surrogate and the run log must say so.

1. Install the Full debug APK (`adb install -t -r app-full-debug.apk`) and open `PairingActivity`.
2. Tap **Scan QR code**. The in-app rationale must appear *before* the OS prompt. Deny the OS prompt:
   the form must return with "Camera permission was denied, so the QR scanner cannot start…" and both
   typed fields must still work.
3. Grant Camera and point at the QR. The scanner returns text only. The form must show `Server: …`
   and `Code: ••••<last two digits>`, with the server/code fields filled and not editable.
4. Nothing may reach `POST /v1/devices/pair/claim` before **Confirm and pair**. After confirming,
   `GET /v1/family/me` must list the device and the app must reach the set-PIN screen.
5. A QR that is not `osra://pair`, a v2 payload, a non-six-digit code or a non-http host must return
   to the form with the stated reason and must not pair.
6. Accessibility: `uiautomator dump` must show `content-desc` on the preview ("Camera preview"), the
   live-region status line and the "Cancel scanning…" button.
7. Cleanup: unpair through the API/parent app, remove protection with the app's parent PIN (§5; not
   `dpm remove-active-admin` on a Samsung), `adb uninstall`, `adb reverse --remove-all`, release the
   lease `Clean`.

**Hardware note (2026-10-19).** The Flip4's rear camera was covered in the test position, so the scan
itself could not be aimed at the monitor; the run verified install, the rationale, the OS prompt, the
camera-ready state and the denial fallback, and the typed path was paired end-to-end against the live
API. The camera → review → confirm steps remain covered by the JVM state machine and are still part of
the open 3.2 hardware row.

## 5h. First-run pairing time (roadmap 3.2, proxy)

`scripts/hardware/android-pairing-time.ps1 -Pin <app PIN> [-Runs 3] [-Base http://127.0.0.1:3000]
[-Apk <full debug apk>]` measures **wall clock from first launch to the screen that says
`This device is paired`**, three times from a clean install each time, driving the real UI with
`uiautomator dump` bounds and `adb shell input tap|text`. It is a measurement: it does not change the
app, and it never sends `lock`. The parent PIN is a run-time parameter and is never logged.

What it does per run: uninstall → `adb install -t -r` → `pm clear` → dismiss the Play Protect
"send for a security check" sheet (*Don't send*; a sideload raises it, a store install does not) →
a fresh code from `POST /v1/devices/pair` → launch → type the API base and the code → **PAIR THIS
DEVICE** → type the PIN twice → **SAVE PIN** → **ACTIVATE DEVICE ADMIN** → **Activate** on the system
sheet → the status screen. Then it unpairs the device row through the API and uninstalls.

How to read the output. The script logs an absolute mark per transition and writes
`pairing-time-runs.json` with the per-step durations, a `overhead` block (cumulative `uiautomator`
dump time, fixed pauses, per-field `input text` time) and the median. **The total is the app plus the
measurement's own eyes and hands**: each screen transition is detected with a dump (~1.1 s on this
host), each tap is followed by a 250–400 ms settle pause, and typing is whole-string injection
(~0.2 s per field) rather than a person's. Subtract `dumpMs + sleepMs` before calling anything the
app's cost, and never present the total as a human's five minutes — it models no reading, no
comprehension and no parent-app step. §5g's QR half and the seven-grant `Setup complete` state are
different acceptance surfaces and are not measured here.

Two traps this script had to absorb: a **sideloaded APK raises the Play Protect sheet over the
launcher** (it blocks every later `uiautomator dump`; dismiss it before launching), and **One UI
reports the system admin sheet's Activate control as `clickable=false` while the click target is its
parent row**. `clickable=false` is AOSP's `device_admin_add.xml` design, not a dead control: the tap
logs `SecDeviceAdminAdd: onClick : Activate the app`. The sheet then closes without an admin because
Samsung's Knox layer throws `IllegalArgumentException: Admin is already added` (diagnosed in #181 —
see §6); the script logs `device_policy after Activate: <bool>` to expose it. On the Flip4 it was
`False` in all three TR-23 runs.

Result of the reference run: `C:\KARIM\tr-kimi\hw-2026-10-19\RESULTS-PAIRING-TIME.md` (21.4 / 21.1 /
21.2 s, median 21.2 s).

## 5i. Verification harnesses for #206 (TR-48, TR-51/52/53)

Two harnesses exist so the two rows no command could prove are runnable. Neither changes product
code; both are measurements, and neither decides the row.

### TR-48 — on-device app list and its sync cadence (`app-list-cadence.ps1`)

```powershell
# parent token + device id from a tr10-state.json (the file tr10-pair.ps1 writes)
.\scripts\hardware\app-list-cadence.ps1 -StateFile C:\KARIM\KCL\tr07\tr10-state.json `
  -Base http://127.0.0.1:3000 [-Serial R5CW116Y6GF] [-Out <dir>]

# or pass them explicitly; -SelfTest runs the fixtures with no phone and no API
.\scripts\hardware\app-list-cadence.ps1 -DeviceId <id> -Token <parent JWT>
.\scripts\hardware\app-list-cadence.ps1 -SelfTest
```

It reads the launchable third-party packages the **device** reports (`pm list packages -3`
intersected with `cmd package query-activities` for `MAIN`/`LAUNCHER`), reads the list the **API
stored** (`GET /v1/devices/:id/apps`, parent token with the `rules` permission), and compares them
as sets. `com.familyshield.agent` is excluded from the device set because the collector skips
itself. The two gated directions are: a launchable user app on the device but not stored, and a
stored package the device no longer has. The documented tolerance is `-ToleranceSeconds` (default
60 s of clock skew): an app whose `firstInstallTime` is at or after `reportedAt` minus that margin
is reported as TOLERATED, because it was installed after the last sync. The reverse direction has
no tolerance: a package uninstalled after the last sync stays stored until the next upload and is
reported STALE. Because that is expected between syncs, the harness **repeats C1–C4 after every
observed change of `appsReportedAt` and gives the verdict from the last comparison** (#221 D2).
The start-of-run comparison is printed as `C0`, information only, so a package removed between
syncs no longer fails a run whose next upload has already corrected the API list. With no observed
change there is no verdict comparison: the run is WAITING (exit 4) and the start rows stay
information, so a re-run no longer has to be timed around a sync.

The cadence half needs two consecutive `appsReportedAt` values 14–16 minutes apart, using the same
rule as the acceptance (inclusive at 840 and 960 s). **The agent uploads only when the list changes
(or when the server copy is 24 h old), so a stationary phone does not move `appsReportedAt` every
15 minutes.** If the current value is at most 16 minutes old it is used as the first endpoint and
one observed change is enough; if it is older, two observed changes are required. If the deadline
(`-CadenceWaitMinutes`, default 35) arrives with fewer marks, the harness prints WAITING and exits
**4** — it does not invent a timestamp, and the row stays open. To exercise the upload path, change
the launcher-visible list on the phone (install/uninstall a harmless app) once per telemetry tick.
Exit codes: 0 PASS, 1 FAIL, 2 setup/usage, 3 device could not be read, 4 WAITING. The PASS/FAIL
table and `app-list-cadence.json` are the evidence for the row.

### TR-51/52/53 — the human five-minute run (`android-pairing-time.ps1 -Human`)

```powershell
.\scripts\hardware\android-pairing-time.ps1 -Human [-Observer "<name>"] `
  [-MarkerFile <path>] [-Out <dir>]
.\scripts\hardware\android-pairing-time.ps1 -Human -SelfTest
```

The five-minute acceptance is a **non-engineer using the QR path**, so a machine-driven run cannot
measure it. `-Human` therefore sends no input events, runs no `uiautomator` dump and does not touch
`adb` at all. It asks for Enter at the script start (person about to launch the app) and at each
boundary the observer reports: welcome, signed in, child added, QR shown, child scanned, and
"Protection: on". With `-MarkerFile` the last mark is the file appearing instead of Enter. It writes
`RESULTS-PAIRING-HUMAN.md` and `RESULTS-PAIRING-HUMAN.json` with the elapsed time per step and the
total, then prints **one** line comparing the total with 300 s.

That line is **informational only**. The script does not pass or fail a human run: a total over
300 s means the row stays open, and a total under 300 s is not a pass by itself — the reviewer
records the run and the checklist decides. The machine-driven mode of the same script is TR-23's
21.2 s proxy and is **not** TR-51/52/53; its banner says so.

Both self-tests run in `workflow-lint` beside `classify-build.ps1 -SelfTest`.

## 5b. Hardware runs on the Windows test host (scripted)

`scripts/hardware/android-signing-tr07.ps1 -Branch <branch>` runs the TR-07 hardware half end to end on a
USB-attached Android phone: builds the agent and the API from `<branch>` under `C:\KARIM\KCL\osra`, pairs
the phone through its own launcher form, fires an SOS through the **OSRA SOS** quick-settings tile (the
`SosActivity` is not exported, so the tile is the only child-side entry), and asserts
`POST /v1/alerts/internal → 201` with `INTERNAL_SIGNING_ALLOW_V1=1` and again with it off. It records the
phone's clock skew (the signing window is ±300 s), screenshots every phone step, and cleans up (§7:
uninstall, `adb reverse --remove-all`, unpair, alert rows deleted). Evidence lands in `C:\KARIM\KCL\run\`.
Needs Postgres/Redis up, JDK 17 (`C:\KARIM\tools\jdk-17`), the Android SDK, and USB debugging authorised.
Traps met while writing it: Java 8 on `PATH` (AGP needs 17), `Get-Date -UFormat %s` returns a *local*
epoch in Windows PowerShell 5.1 (use `[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()`), `adb exec-out
screencap` prefixes a text warning on multi-display phones (strip to the PNG signature), and a child
process started with `Start-Process` inherits the console's redirected log handle and keeps it locked
after its parent dies.

## 6. Traps that have cost real time here

| Trap | What happened | Rule |
|---|---|---|
| `settings put secure enabled_accessibility_services` with the short component (`pkg/.services.X`) | One UI (Android 16) accepted the write and silently dropped it: the status screen said "Missing: Accessibility service" and the guard/lock re-raise were off for the rest of the run | Always write the **full** class name: `com.familyshield.agent/com.familyshield.agent.services.AccessibilityMonitorService`; read it back with `settings get` before trusting it |
| `am start-foreground-service` from `adb shell` on a non-exported service | Android 14+ answers `Requires permission not exported from uid …`; the service looked "started" (`ServiceRecord … app=null`) and nothing polled | Start the agent through its launcher activity (`am start -n …/.setup.PairingActivity`) or by enabling the accessibility service; never rely on a shell service start |
| `media volume` is not on One UI | `ping`-style scripts that read the alarm stream got blank values | Use `cmd media_session volume --stream 4 --get` / `--set N` |
| A PowerShell wrapper around `adb` eats `-c`, `-d`, `-s` | `adb shell ping -c 1` and `adb logcat -d` inside a function ran without their flags (logcat then streamed forever) | Call the exe directly for anything with dash arguments; `$host` is a reserved variable |
| `uiautomator dump` on the One UI VPN screen | "could not get idle state" forever (the screen animates) | Screenshot + tap at coordinates for that screen; everything else dumps fine |
| A 401-after-revocation check (e.g. probe F8) fails once, then passes on re-run with no code change | `iat` was per-second and the comparison was `iat < epoch`, so a token minted in the same second as the revocation survived — the server bug behind #117; #110/#111 changed only the probe and waited out the symptom. Fixed 2026-10-18 | Since ADR-0025 / #117 revocation is a counter (`sv`), not a clock: a token minted in the revocation second is dead **by design**, and a login after the revocation works in that same second (probe F8 and N2 rely on this; their boundary waits are gone). Do not reintroduce `Date.now()` into the comparison. Keep asserting the fresh token **works** (`GET /v1/family/me` → 200), not merely that login returned 200 — `qa-probe` F8, #110/#117 |
| `check-probe-integrity.mjs` reports a probe assertion as **REMOVED** although the line is still there | The checker only reads a literal name that opens on the **same line** as `check(`; a wrapped call — `check(` then the name on the next line — is counted as *dynamic* and therefore looks deleted. Separately, `--head HEAD` compares the **committed** tree, not your working copy, so an uncommitted reformat is invisible and the removal persists | Keep the assertion name on the `check(` line (the probe's existing style), and run the checker with no `--head` for a working-tree comparison: `node scripts/check-probe-integrity.mjs --base origin/main`. Hit on #111: the name set matched 88/88 by hand while the gate stayed red |
| The JVM `LockEnforcementPolicyTest` is green and the device still locks the wrong window | The test proves the **rule**, not the device's package names: on the Flip4 the emergency dialer is `com.samsung.android.emergency`, which no AOSP name contains (issue #80) | Treat probe row **S1** as the only proof that the lock leaves the dialer reachable; a green JVM suite is necessary, never sufficient |
| A bedtime / school / allow-list rule covers the **home screen**, and Home does nothing on the phone | The rule is evaluated for whatever is in the foreground, so "block" was answered for the launcher too. Before issue #165 only the empty-cache path consulted the essential list, and the JVM suite was green because it never asked what the launcher package is. Seen on the Flip4 during TR-22 (relaunch after midnight, seeded bedtime 21:00–07:00; evidence in `C:\KARIM\tr-kimi\hw-2026-10-19\RESULTS-ROW3.md`) | The essential set (`enforcement/EssentialPackages.kt`) is consulted before any rule, and `AppBlocker` re-checks with `PackageFacts` (HOME role + system dialer). Verify on hardware with the #165 check: after Home, `dumpsys window \| grep mCurrentFocus` names the launcher, `adb shell am start -a android.intent.action.DIAL` reaches the dialer, and a named blocked app still shows the overlay. Do not add one package name to the table to fix one device without checking the role path, and never "fix" the report by removing the bedtime rule |
| An accessibility event's **package is not always the app in front** — the launcher is blocked although its name is in the essential set | The fix for #165 held in JVM and failed on the phone: with bedtime active on the Flip4 (Android 16, WM-Shell), the Home transition arrives as a `TYPE_WINDOW_STATE_CHANGED` event whose `packageName` is **`android`** (the framework), not `com.sec.android.app.launcher`. The overlay's subtitle showed the evidence — the package handed to `showBlockScreen` was `android` — and `EssentialPackages` never had that name (`C:\KARIM\tr-kimi\hw-2026-10-19\RESULTS-165.md`, rows 3a/3b) | Decide from the window in front, not from the event: `EssentialPackages.foregroundPackage(eventPackage, windowPackage)` takes the event's package as a **hint** and the active window's package (event source, else `rootInActiveWindow`) as the authority. `AccessibilityMonitorService` resolves once per event and uses the result for the guard, the lock, the usage counter and the block decision; `android` alone resolves to `null` and raises no overlay. Do **not** add `android` to `EssentialPackages.EXACT` — it fronts dialogs and shell surfaces, so it would exempt far more than Home. Check every consumer of "which app is in front" when touching this |
| A block/lock decision is JVM-green and the blocked app still **shows beside or above** the overlay | #171 decided from `rootInActiveWindow` alone, so an app that was visible but not active was never named: a YouTube video in PiP over Home made the launcher (essential → ALLOW) the only decision, and the other half of a split screen did the same (issue #175) | `AccessibilityMonitorService.windowSnapshot()` reads every `TYPE_APPLICATION` window including `isInPictureInPictureMode`, and `EssentialPackages.blockCandidates` runs the same rules on the active app **and** the other visible ones; `LockEnforcementPolicy` answers from the same snapshot. The overlay activities are `resizeableActivity="false"` (the public way to leave split) and `supportsPictureInPicture="false"`. There is **no** public way to close another app's PiP window: `setPictureInPictureParams` belongs to the target, so a PiP video may stay above the overlay — re-raising is bounded by `OverlayRetryBudget` (3 per window-state signature) and the visual result is a **hardware** row, not a JVM claim. Measure both things on a clean phone: the overlay is up, and whether the video keeps playing over it. Do not "fix" this by adding an audio-focus pause without the measurement (ADR-0026) |
| A security exemption is written as `startsWith("<our own package namespace>.")` | `EssentialPackages` exempted every `com.familyshield.*` name from every block rule, so a sideloaded app could call itself `com.familyshield.notanapp` (or exactly `com.familyshield.`) and escape bedtime, blocklists, pause, screen time and the overlay. The Full build is the sideloaded artefact and Android does not reserve a namespace; the prefix was meant for "our own components", which is a finite set (issue #192, found in the 2026-10-19 ledger review) | Exempt **exactly** the package(s) the app is built under (`applicationId` in `apps/child-android/app/build.gradle.kts`, currently `com.familyshield.agent` for both flavours) as an explicit allow-list — never a namespace prefix or a `startsWith` on a shorter string. Keep the OS-assigned roles (HOME, dialer) as dynamic tests; those are surfaces, not names. The JVM pin is `EssentialPackagesTest`: the agent package is essential, while `com.familyshield.notanapp`, `com.familyshield.agent.notanapp` and the prefix-equal `com.familyshield.` stay blockable through both `isEssential` overloads |
| Probe row S1 reads "LockActivity on top" on a phone with a secure lock | `lock` is a real `lockNow()` (ADR-0010): the OS keyguard sits above `LockActivity` **and** above anything `am start` launches, so the dialer can never reach the front whatever the policy does | Unlock the phone (swipe or PIN) with the lock overlay up before measuring. The probe now reports the row as **NOT MEASURED** and exits non-zero instead of FAIL (`scripts/hardware/android-bypass-probe.ps1`, 2026-10-17) |
| `FATAL EXCEPTION: main … ForegroundServiceDidNotStartInTimeException` in a receiver, although the service saw the missing permission and called `stopSelf()` | `startForegroundService()` starts a clock that only `startForeground()` stops: returning `START_NOT_STICKY` and stopping **without** ever calling `startForeground()` still trips the deadline. "Check the permission inside the service and bail" is therefore not a safe pattern | Guard **before** `startForegroundService()` — `BootStartPolicy` (issue #128). A service that cannot legally start foreground must not be requested at all |
| A new `ContextCompat.startForegroundService(… LocationService::class.java)` call site is added with a fine/coarse check only | #128 fixed boot, but `AccessibilityMonitorService` and `locate_now` kept starting the location FGS on a while-in-use grant alone; Android 14+ refuses a location FGS created from the background without `ACCESS_BACKGROUND_LOCATION` (issue #132). A JVM test of the policy proves the rule, not that the new call site asks it | Route background starts through `LocationStartPolicy` (fine **or** coarse plus the background grant on API 29+). Foreground-activity starts go in `LocationServiceStartSitesTest.FOREGROUND_START_SITES` with the reason; the test fails for any unlisted site without a policy reference. A refused `locate_now` must ack `failed` with `detail.reason = background_location_missing` so `/commands/history` shows it |
| A work order says "run S1 with the app PIN" and the run stops at the phone's lock screen | **the app PIN (set during pairing, held outside this repo) is the OSRA parent PIN** — it opens the in-app gates ("Remove protection", stop ring). It is not the device keyguard credential, and `adb shell locksettings verify --old <app PIN>` answers "didn't match" on the Flip4 (2026-10-18, TR-21) | Never send `lock` on a phone whose keyguard PIN you do not hold: `lockNow()` raises a screen nobody in the room can dismiss. Ask the maintainer to unlock, or measure the `pause` overlay instead — it exercises the same `LockActivity` + policy + `<queries>` path and is honest only when labelled as a surrogate, never as S1 |
| `dpm remove-active-admin` fails with `SecurityException: Attempt to remove non-test admin` during cleanup | The APK on the phone does **not** declare `android:testOnly` — either it is a **release** build (correct: it keeps the hard admin and wants the app PIN), or it is a debug build from before #170 — and a leftover admin blocks `adb uninstall` | Do not reach for this command as cleanup: since #217 the documented route for **every** build is the app's **REMOVE PROTECTION (PARENT PIN)** (§5), which is Knox-aware on Samsung. `dpm remove-active-admin` is a last resort for an AOSP phone, or for an admin set with `dpm set-active-admin`; on a Samsung whose admin came from the system sheet it strands Knox's registry row and the next activation fails with `Admin is already added` (#202). A **release** build must not have `testOnly` (the merged-manifest tests assert its absence), so on release the PIN gate is the only route. Check `dumpsys device_policy` shows the agent gone **before** uninstalling, or the cleanup half-fails and the next run starts from a dirty phone |
| A hardware table says **PASS** but the run measured the debug APK | Since #170 every debug build is `testOnly` and `debuggable`; its admin is a test admin, `adb install -r` replaces it without a signature match and `dpm` removes the admin. The tamper rows (1, 2, 10, force-stop) were measured that way for weeks, and a PASS on them says nothing about the release artefact (issue #178) | The probe now classifies the installed package from `dumpsys package` (`flags=[ … TEST_ONLY … DEBUGGABLE … ]`) plus `run-as`, and **refuses with exit 3** unless `-AllowTestBuild`; under that switch evidence is prefixed `NOT EVIDENCE (testOnly/debuggable build)` and `bypass-probe.json` has `gateEligible: false`. Gate-eligible Phase 1 rows need the release-signed APK; see `QA/TESTING-STRATEGY.md` §3b and §5f. Run `classify-build.ps1 -SelfTest` after touching the decision |
| **Samsung: the system device-admin sheet's Activate closes without activating; logcat says `IllegalArgumentException: Admin is already added`** | On the Flip4 (One UI 16, Android 16, `SecDeviceAdminAdd`) the tap is **not** inert: `I SecDeviceAdminAdd: onClick : Activate the app` runs `addAndFinish()`, then Samsung's Knox layer throws `W SecDeviceAdminAdd: Exception trying to activate admin ComponentInfo{com.familyshield.agent/…FamilyShieldDeviceAdmin}` / `java.lang.IllegalArgumentException: Admin is already added`; `addAndFinish` catches and still calls `finish()`, so the sheet closes and the app says `⚠️ Protection: alert-only`. `dumpsys device_policy` has **no** active OSRA admin, but `D EnterpriseDeviceManagerService: Admin found on user 0: …` appears before the throw because Knox keeps its own admin registry (`mAdminList`/`mAdminMap`, persisted by `EdmStorageProvider.addorUpdateAdmin`) and `EnterpriseDeviceManagerServiceImpl.activateAdmin` rejects a component it already lists. The row is created by an activation **through the sheet** and is **not** removed by AOSP `DevicePolicyManager.removeActiveAdmin`: measured 2026-10-19 by activating a fresh debug-only receiver via the same sheet (success, `Adding admin … to lists`), running `adb shell dpm remove-active-admin` (Success, **no** Knox log), then re-opening the sheet → `Admin found on user 0` → Activate → `Admin is already added`. It survived `pm uninstall` + reinstall with a **new uid**, because `getActiveAdminLocked` matches the **component + user**, not the uid. Ruled out: the click target (`clickable=false` is AOSP's `device_admin_add.xml`; the clickable `restricted_action` parent handles the tap), `testOnly` (a build with `src/debug/AndroidManifest.xml` removed fails identically), the intent (the sheet shows the right component/description/policies and `dpm set-active-admin` works), and a scroll/second confirm (the first tap reaches `addAndFinish`). Issue #181 | Do not chase `clickable=false` or reinstall the app. Grep the **tap moment** for `SecDeviceAdminAdd` and `EnterpriseDeviceManagerService`; `Admin found on user 0` + `Admin is already added` is this trap. On a Samsung test phone, deactivate an active admin through **Settings → Security and privacy → Device admin apps → OSRA parental controls → Deactivate** (the Knox path clears its row) **before** uninstalling; use `dpm remove-active-admin` only for an admin that was set with `dpm set-active-admin` (AOSP, never registered with Knox). A phone already poisoned for the component cannot be fixed by reinstall: the row survives uninstall and a new uid. **The recovery is a component rename, not a factory reset (issues #202, #217):** because Knox matches component + user, moving the receiver to a class name Knox has never seen puts it outside the stale list and the same sheet activates it. This has now happened **twice**: #209 moved `…FamilyShieldDeviceAdmin` → `…ParentalAdminReceiver`, and #217 moved `…ParentalAdminReceiver` → `…GuardianAdminReceiver` after the cleanup command above stranded a row for the second name on the Flip4. The root cause is `dpm remove-active-admin` on a sheet-activated admin, not the class name — §5 no longer prescribes that command. The class, the manifest entry, the `device_admin.xml` consumer and the code constant must move together — `AdminReceiverContractTest` fails a half-landed rename, and the merged-manifest gate asserts the installed component in both flavours. Measured 2026-10-19 on the Flip4 with the Full debug build (test-only, #178): the sheet's Activate returned `device_policy after Activate: True`; `dumpsys device_policy` read back `com.familyshield.agent/.security.ParentalAdminReceiver` (the name shipped at the time) with `policies: watch-login, force-lock`. In-app Remove protection (parent PIN) then returned the phone to `alert-only` with 0 OSRA admins, and re-activation through the same sheet succeeded again (#187 AC1's second half). Root/system access to the EDM database also clears the row, and a factory reset is the last resort, not the procedure. Related product finding (#186, fixed here): the app's own `DeviceAdminManager.removeAdmin()` used the same AOSP removal, so removing protection and later re-enabling it through the sheet was expected to hit the same trap. Since #186 the in-app removal is **Knox-aware**: `AdminRemovalPolicy` probes `com.samsung.android.knox.EnterpriseDeviceManager` by reflection and, when the admin API is present, deactivates through `setActiveAdmin(component, false)` before falling back to AOSP; on every other OEM and after any reflection failure it behaves exactly as before. This does **not** change the hardware-cleanup rule above: `adb shell dpm remove-active-admin` is an AOSP-only shell call that bypasses the app, so on Samsung deactivate from Settings (or use the app's PIN-gated Remove protection) **before** uninstalling. Enrolment now names the dead end when the sheet returns with zero AOSP admins on a device that has Knox, and offers Settings → Device admin apps; it does not self-heal another layer's registry. Acceptance 1 of #186 (remove → reinstall → activate through the sheet on the Flip4) is hardware-blocked by the phone's existing stale row |

Hardware-host traps above (2026-10-17, TR-13…18); build/API traps below.

| Symptom | Cause | What to do |
|---|---|---|
| A suite is red only for **two hours a day** (here 00:00–02:00 local), with a `Found 0 widgets with text "<weekday>, <date>"` or `Bad state: No element` in `scrollUntilVisible` | The fixture derives timestamps from `DateTime.now()` and the assertion derives a **day/date string** from the same clock. In `apps/parent-app/test/social_screen_test.dart` the seeded `now - 40 min` crossed midnight at 00:00–00:40 (this morning's header vanished) and `now - 26 h` landed two days back at 00:00–02:00 (`reveal(<yesterday>)` threw `Bad state: No element` at `:265`). It made the `parent-app` job red daily and took every open PR with it (issue #176, reproduced 2026-10-19 00:55Z) | Pin the fixture's base time — or inject a clock the product already accepts (`PairQrScreen`'s `clock:` is the existing seam; do not add one the screen does not need) — and derive **every** seeded timestamp from it. Seed the timeline from calendar fields (`today`, `yesterday`), never `base ± Duration`, and keep a 00:00 and a 23:59 fixture asserting the same day headers. Grep before assuming you are done: `grep -rn "Duration(hours\|Subtract\|now()" apps/parent-app/test`; a `now`-derived seed is safe only when the expectation is derived from the same seed, not from the wall clock |
| Every manifest test is green and the **store build still carries a Play-forbidden permission** | The manifest tests read **source** files (`app/src/main/AndroidManifest.xml`, `app/src/full/AndroidManifest.xml`), and CI's `aapt2` step only ran `dump badging` — which prints no permissions. Manifest merging is where a **dependency's** declarations arrive: a library that ships `READ_SMS`, `READ_CALL_LOG`, `QUERY_ALL_PACKAGES` or a notification listener puts it in `merged_manifests/<flavor>Debug/…/AndroidManifest.xml` and in no file this repository wrote. Every gate stayed green through #100/#106/#131 (finding F2, #101 review) | The gate is `PlayMergedManifestTest` / `FullMergedManifestTest` (`apps/child-android/app/src/test/java/com/familyshield/agent/manifest/`): they parse the **merged** manifest and assert a **reviewed allow list** plus a **deny list** (ADR-0021 decisions 1/2/5), the Full build's capture permissions and listener, `isMonitoringTool` in both flavours, and the three dialer `<queries>` S1 depends on. `node scripts/check-merged-manifest-gate.mjs` fails CI if the gate skipped or a named assertion disappeared. When it goes red, the merger names the source: `app/build/outputs/logs/manifest-merger-play-debug-report.txt` (and the per-element blame file next to it, `app/build/intermediates/manifest_merge_blame_file/playDebug/**/manifest-merger-blame-play-debug-report.txt`) |
| Test counts look unchanged after a change | **Stale test XML** from a previous run (the suite never re-ran) | Check the timestamp of `app/build/test-results/...`; delete `app/build` and re-run |
| A background build reports a **plausible but wrong** test count, after you changed branches while it ran | The build compiles whatever is in the working tree at the moment it gets there; in a shared clone a `git checkout` mid-build silently swaps the source, so the numbers belong to different code (hit on 2026-10-17: a `#78` build produced `main`'s 27 suites / 179 tests, which looked entirely reasonable) | **Freeze the working tree until the background task finishes**, or build in a separate `git worktree`. Then `git rev-parse --short HEAD` *while reading the results* and confirm it is the sha you meant to test; delete `app/build/test-results` before a re-run so nothing stale can be counted |
| `BUILD FAILED: Unable to delete directory …build/tmp/kotlin-classes` | Windows file lock (indexer/Drive sync/daemon) | `./gradlew --stop`, delete the build dir, re-run; retry once before assuming a code error |
| `prisma generate` → `EPERM: rename …query_engine.dll.node` | A running API holds the engine DLL | Stop the API, generate, restart. If the API is not yours and you may not stop it, generate against a second checkout instead |
| The shared `:3000` API **refuses connections mid-session**, and its own log ends on `200`s with no stack trace | It was started inside an agent's task manager, and stopping a sibling task killed the process group — observed twice on the host PC (issue `#71`) | Do not host the shared API inside an agent task: start it detached (your copy of `start-backend.bat` — `docs/test-guides/start-backend.example.bat` ships in the repo — or `nohup … &` with output redirected). If you find it down, **say so on the board rather than starting a second instance** — the second start fails with `EADDRINUSE` and makes a healthy environment look broken. Then check the dead process's log: clean end = killed, not crashed |
| An API on a spare port answers `curl` with **nothing** and a Node script dies on `fetch failed` / `connect ECONNREFUSED ::1:<port>` — while `netstat` shows it **LISTENING on `0.0.0.0:<port>`** | The server bound IPv4 only, and `localhost` resolved to `::1` first on this host. It looks exactly like a dead server, which is why it reads as an outage | Use `127.0.0.1` in `API_BASE` (and in `curl`) for spare-port instances, or bind `::`. Bit me twice today: `qa-probe` exited 1 against a server that was up, and `curl http://localhost:<port>` returned empty |
| `git push` hangs for minutes with no output, and `curl`/`gh api` against `repos/handfullofluck-lab/osra` return **404** — while `git ls-remote` and `gh pr list` still work | The `ghp_…` token copied into scripts/`GH_TOKEN` was rotated; the `gh` CLI and Git Credential Manager now hold a **fine-grained PAT** from the keyring. The stale token authenticates (so nothing says "bad credentials") but is not authorised for this repo, which GitHub reports as 404 | Do not override `GH_TOKEN` with the old token. Push with plain `git push` (keyring), use `gh` without overrides, and read the live token with `gh auth token` only when a script genuinely needs it. Verified 2026-10-17: the same push that stalled four times for 4+ minutes completed in 67 s on the keyring credential |
| "Gates green" but nothing ran | Pipe masking: `cmd \| tail` hides the real exit code | Check `${PIPESTATUS[0]}`, or grep the output for the failure |
| A workflow shows as failed with **0 jobs** | GitHub rejected the workflow file (schema), YAML parsers accept it | `node scripts/check-workflows.mjs --strict` |
| A PR shows **"No checks reported"** — an empty checks area, no `pull_request` run queued — while every other PR is running CI normally | **The branch conflicts with its base.** GitHub runs `pull_request` workflows against the synthetic merge commit `refs/pull/<n>/merge`, and it creates no such ref for a PR whose `mergeable` is `CONFLICTING` — so the workflow is never triggered at all. "No checks" is not "pending": waiting for it never ends. Diagnosed on #96 (2026-10-18), where it read as "CI did not start" before the merge ref was suspected | Confirm the state (`gh pr view <n> --json mergeable,mergeStateStatus` → `CONFLICTING`/`DIRTY`), then **merge the base into the branch and push**: `git fetch origin && git merge origin/main`, resolve, `git push`. The merge ref appears and the run starts. Never report a PR as "CI pending" on an empty checks list, and never merge one: an unmergeable PR by definition has no merge commit to gate |
| An issue closes itself when a PR merges, although the PR said it should stay open | GitHub matches `close #N`, `fixes #N` and `resolves #N` anywhere in a PR body, **even negated** — "does not close #136" closed #136 when #144 merged (TR-80, 2026-10-19) | Never write a closing keyword next to an issue you mean to leave open; write "leaves #N open". Check the PR's linked issues before merging. Commit messages that land on `main` count too (`0b32f43` closed it a second time), and if it happens, reopen the issue and say why on it. |
| Connections fail for some apps after agent testing | WinINET proxy left on a dead `127.0.0.1:8877` (and the `Connections` blob survives `reset-proxy.bat`) | See issue `#32`; delete the `Connections` values after resetting. Set `FS_SET_SYSTEM_PROXY=0` for developer machine test isolation; `reset-proxy.bat` now flushes WinINET immediately |
| Emulator: no location, ever | Emulator GPS injection does not reach agents | Verify location on the physical device only |
| CI: `Process completed with exit code 126` | A committed script lacks the executable bit in git (Windows-authored repos strip it) | `git update-index --chmod=+x <file>`; check both `gradlew` wrappers, `.sh` scripts and `.githooks/*`. This bit `gradlew` (the Android job) and the pre-push hook itself — on a Linux/macOS clone the hook would not have run at all |
| A running API dies right after you regenerate the Prisma client | `prisma generate` rewrites the client files the running process has loaded | Treat "migrate + generate" as a restart-and-start sequence: stop the server, `prisma generate`, start it. The deploy scripts do this for you; doing it by hand under a live server will kill it |
| API refuses to boot with `[SchemaDrift] …` | `assertPrismaClientInSync` comparing the generated client against the database (by design — issue #47) | Run what it tells you: `pnpm --filter @familyshield/api exec prisma migrate deploy && pnpm --filter @familyshield/api exec prisma generate` |
| `PrismaClientValidationError: Unknown argument <field>` / `400 invalid_input` on writes right after a schema migration | Generated Prisma client predates the DB migration (`#47`) | Run `pnpm exec prisma generate` (or run `pnpm db:migrate` which now chains `deploy && generate`). The API boot check (`assertPrismaClientInSync`) fails fast on schema drift |
| `e2e.mjs` aborts with `Error: ws timeout` and the summary never prints | **Not fully explained.** The old harness armed a one-shot promise on the socket and posted the alert the instant `open` fired, and an abort in that window records **0 FAILs**, so the remaining ~30 checks silently never run. My first hypothesis — the frame is published before the server registers the socket, which happens after the ticket's Redis `GET`+`DEL` — **did not reproduce**: 20/20 immediate-post trials delivered (TR-04 measurement, 2026-10-16) | The harness (TR-04) collects frames, re-posts the alert up to 3× if no frame arrives, and prints `frames=`, `wsError=` and `wsClose=` on failure — so the next abort is explicable instead of mysterious. Since TR-05 the gateway sends `{type:"ready", familyId, ts}` as the **first frame on every socket** (after it registers the socket) and the harness waits for it before posting the alert, replacing the Redis ticket polling; the probe asserts the contract (L1–L5). An alert lost **after** `ready` was received is a subscriber finding, not a race. See `services/api/scripts/e2e.mjs` §7. Read the line count, not just "no failures"; do not loosen the assertion |
| A committed cleanup script deletes more than expected | `cleanup-test-data.sql` restores the **database**; per-device Redis keys are invisible to it, and `revoked:device:*` is security state, not residue (`#56`) | Use `scripts/cleanup-test-redis.mjs` (dry run by default) rather than `redis-cli` by hand. Per-device keys are only ever deleted with their owner row. Since TR-05 `revoked:device:*` is written with `EX` = the device-token lifetime (`DEVICE_TOKEN_TTL_SECONDS`, 10 y) and `refresh:index:*` re-arms a 30 d TTL on every login — bounded, never reaped: a key that still has `TTL -1` predates the fix and gets its bound on the next write to it |
| `git push` hangs with **no output** and never returns | Git Credential Manager (`credential.helper=manager`) waiting on an interactive prompt in a non-TTY shell — `git fetch` on the same remote still works, which makes it look like a network problem | Supply the credential non-interactively for that one command: `git -c credential.helper='!f(){ echo username=x-access-token; echo password=$GH_TOKEN; }; f' push origin <branch>` with `GIT_TERMINAL_PROMPT=0`. Observed 2026-10-16 on the host PC; a `git fetch` in the same shell had just succeeded |
| A device JWT reads a **sibling child** in the same family, but every cross-family test is green | `requireFamily` compares only `familyId`, and **every device in a family shares it**. Unit tests usually mint parent tokens (`authHeader`), so the device path is never exercised against a sibling child. Found in the location/rules audit (2026-10-18) | On routes a device may call, pass `deviceAccess: "own-child"` to `requireFamily`; assert both halves — own child **200**, sibling **403 `cross_child_forbidden`** — with `deviceHeader` (`test/location-auth.test.ts`, probe G13/G14). Family isolation alone is not child isolation |
| `dotnet test` on the Windows suite locks the developer's session | `ScreenTimeEnforcer.Evaluate` calls `LockWorkStation()` for a bedtime window, and `LockOverlay.Show` starts a WinForms message loop; a test that exercises either without the seams locks or flickers the desktop it runs on | Replace `LockWorkstationAction`, `ShowOverlay` and `HideOverlay` in the test (see `ScreenTimePinGateTests`); the root-CA install path additionally stays behind `FS_HTTPS_INTEGRATION=1` because it writes `CurrentUser\Root` |
| Windows agent locks refuse to arm and the log says "no parent PIN is configured" | By design since `fix/desktop-pin-and-tls`: there is no default PIN (the old `0000` is refused), and lock/bedtime/screen-time stay disarmed until one is set | Enter a 4–8 digit PIN at pairing, or on an install without `parentPin` in `agent.config.json` set `DESKTOP_PARENT_PIN` and restart once — it is adopted into the file |
| `qa-probe` stops with `ABORT: rate limited by the API (n x 429) - wait 60 s and re-run` and exit **2** | The shared `:3000` instance rate-limits 200 requests/min per IP (auth routes 20/min). Three concurrent probes — or another agent's run in the same window — produce 429s. Before #112 those were recorded as product failures (one measured run: 66 x 429 → 27 "failures") | This is the **tool working**, not a defect: exit 2 means rate limited, exit 1 means a real assertion failed. Wait 60 s and run the probe alone. Since #112 `call()` counts every 429, retries once only when `Retry-After` ≤ 3 s, and aborts before a 429 can become a `FAIL`; the summary line carries `rate limit: N x 429`. The API log double-logs each response (an error line plus a `request completed` line), so count `Rate limit exceeded` entries, not `statusCode":429` lines |
| A test that pins "a `password_reset` token is refused by `requireJwt`" passes against the **unfixed** code | The token was minted **before** `/reset/confirm`, so `isParentSessionLive` rejected it through the sessions-invalid-before epoch (`iat < epoch`) — the test looked green while the purpose check was absent, because it never reached the handler | Mint the purpose token **after** the reset (or with `iat` ≥ the epoch) and send the password the reset just set: only a purpose check can refuse that call. Assert both with and without the re-auth password — #146, `test/auth.test.ts` |
| Unit tests are green on a Redis command the **shared test server** cannot run | The shared server runs **Redis 5.0.14**; anything newer than that is `ERR unknown command`. `MockRedis` used to implement `getdel`, so `/reset/confirm` passed 442/442 in CI while every confirm on the live stack answered `500 ERR unknown command 'getdel'` (#167, 2026-10-21) | Consume atomically with the Lua `GET`+`DEL` script (`services/api/src/routes/devices.ts:217`, used by `/pair/claim` and `/reset/confirm`). `MockRedis.getdel` now **throws** Redis 5's error on purpose — do not "fix" it by returning null; mock `eval` over the Map store instead (`test/pairing.test.ts:34`). A command newer than 5.0 needs a live-stack row, not just a green suite |
| A test asserts a status the production server would never send, or the opposite | `buildApp` did not install `server.ts`'s error handler, so a route that rethrows saw Fastify's default instead of the real mapping (anything `/prisma\|invocation/` → `400 invalid_input`). That hid #167's "400, not 5xx" from the suite | `buildApp` (`test/helpers.ts`) now calls `registerErrorHandler` from `src/lib/errorHandler.ts`, the same function `server.ts` uses. Keep the handler in that module — importing `server.ts` from a test boots Redis, Prisma and the listener |
| A reviewer asks why `qa-probe` does not prove the **device-silence alert fires** | The watch is an in-process 5-minute tick (`src/jobs/deviceSilence.ts`) with no HTTP trigger, and the probe connects over HTTP only (`API_BASE` + `INTERNAL_HMAC_SECRET`; it has no `DATABASE_URL`). Making a device silent needs a backdated `Device.lastSeen`, then either a ≤5-minute wait or an in-process job call — and a real `runDeviceSilenceCheck()` on the shared stack would also alert on unrelated stale rows | Do not "fix" this by adding `DATABASE_URL` to the probe. The gate asserts the half that is reachable: a real telemetry POST reads back `status:"online"` — the value the watch matches, not `active` (probe `G22`), and no writer produced a status outside the shared vocabulary (`G23`). The alert-per-episode half stays a unit test (`test/device-silence.test.ts`), which drives the route's status into `runDeviceSilenceCheck(now, env)` with a backdated row |
| In a **fresh worktree** set up per the brief (`pnpm install --filter "@familyshield/api..."`), `e2e.mjs` with `DATABASE_URL` set dies at the final row-count step with `Cannot find module '@prisma/client/runtime/library.js'` (exit 1, **no summary line**) | `prisma generate` writes the client to the workspace root `node_modules/.prisma/client`, whose `index.js` requires `@prisma/client/runtime/library.js`; the filtered install puts `@prisma/client` only in `services/api/node_modules`, so that lookup fails from the root | Link the package where the generated client expects it (environment-only, `node_modules` is gitignored): `node -e "require('fs').symlinkSync(require('path').resolve('node_modules/.pnpm/@prisma+client@<version>/node_modules/@prisma/client'), require('path').resolve('node_modules/@prisma/client'), 'junction')"`. Without `DATABASE_URL` the same run only prints a `NOTE` and skips the check — that skip is not a pass. Measured 2026-10-18 in `wt-p124probe`: before the link the run lost its summary after 68 passes; after it, **69 passed, 0 failed** with the zero-rows count |
| `e2e` stops with `ABORT: rate limited by the API (n x 429) - wait 60 s and re-run` and exit **2** | The same shared limiter as the probe, one minute later in the same sitting. Before #126 e2e recorded the throttled `/me` calls as two `FAIL`s and then crashed at `e2e.mjs:89` with `TypeError: Cannot read properties of undefined (reading 'find')`, so the remaining ~60 checks never ran and no summary printed (measured 2026-10-18 on `main@7435592`) | The **tool working**, with the probe's contract: exit 2 = rate limited, exit 1 = a real assertion failed. Wait 60 s and run e2e alone. Since #126 `call()` counts every 429, retries once only when `Retry-After` ≤ 3 s, and aborts above 5 without a `FAIL`; a missing `/me` envelope prints the response body and the `=== E2E: n passed, m failed ===` summary and exits 1. Verified in `test/e2e-rate-limit.test.ts` (all-429 stub and a `/me` stub without `children`) |

| `check-workflows.mjs` is green but GitHub runs a workflow with **0 s, no jobs** | The linter matches text; it cannot tell that a comment lost its `#` and became a bare line, or any other YAML error. GitHub then rejects the whole file and the run has no jobs, which looks like a cancelled workflow (2026-10-19: `verified-gate.yml`) | `workflow-lint` now runs `yaml.safe_load` over every workflow file. Locally: `python3 -c "import yaml,glob; [yaml.safe_load(open(f)) for f in glob.glob('.github/workflows/*.yml')]"` |

| A PR's diff is huge in the opposite direction from its title — e.g. a `docs(...)` PR that deletes 500 lines of Kotlin | A squash or rebase built on a **stale base**: the tree is the old base plus your edit, so the diff *is* the revert. CI stays green because the tests run on that tree and prove the old code works (hit on 2026-10-19: a #220 squash would have reverted #218 entirely) | `node scripts/check-pr-diff-scope.mjs --title "<title>" --base origin/main --head HEAD` before every push to a docs or CI branch; `workflow-lint` now runs it for every PR. Rebuild with `git checkout -B <branch> origin/main` and re-apply the hunks |

| A `fix(...)`/`feat(...)` PR quietly undoes an earlier merge, with a small and plausible diff | The title check cannot see it: the diff is the right *shape* for a code PR, but its **values** are the pre-merge ones. This is how a stale-base revert would arrive if it wore a code title instead of a docs one | `node scripts/check-pr-diff-scope.mjs --title "<title>" --base origin/main --head HEAD` — it compares each path's blob against the last 30 first-parent merges and fails when the PR restores a pre-merge blob while `main` carries the merged one. Only a `revert(...)` title may do that |

## 7. Definition of done (tests)

A change is done when **all** of these are true (`AGENTS.md` §3): the API unit suite is green, the probe
is green **including the new checks for the behaviour you changed**, e2e is green, the platform suites
for what you touched are green, a test exists that *failed before* the fix, and the docs (changelog,
ADR if the decision was architectural, this guide if the procedure changed) are updated.

**Hardware cleanup is part of done (issues #170, #217).** A run that leaves the device admin standing
is not finished (§7 of `AGENTS.md`). The documented route for **every** build is the app's
**REMOVE PROTECTION (PARENT PIN)**, then `adb uninstall` (§5); that removal is Knox-aware on Samsung
since #186 and is the route the product itself uses. **`dpm remove-active-admin` is a last resort, not
the debug cleanup**: it removes AOSP's admin but on a Samsung whose admin came from the system sheet it
leaves Knox's registry row, and the next UI activation fails with "Admin is already added" until the
component is renamed (#202, #217). It may be used off Samsung, or for an admin set with
`dpm set-active-admin`, and the run log must say so. A **release** build deliberately does not carry `testOnly` — it would make
the APK replaceable without the parent's consent — and is cleaned up exactly the same way, through the
app's PIN gate. Never add `testOnly` to a release manifest to make a cleanup easier:
`PlayMergedManifestTest` / `FullMergedManifestTest` assert its absence in both release merges.

### A PR that touches the probe must not narrow it — and that is now machine-checked

`AGENTS.md` §4 forbids weakening a check to make a gate green, but until now the rule was only
enforceable by a tester reading the diff by eye. That is not a control: PR #65 rewrote the signing
helper and moved two targets to gates inside a **225-added / 43-deleted** change to
`services/api/scripts/qa-probe.mjs`, and an assertion that quietly disappears looks exactly like an
assertion that was renamed.

```bash
node scripts/check-probe-integrity.mjs                                  # origin/main -> working tree
node scripts/check-probe-integrity.mjs --base origin/main --head origin/<branch>
```

It compares the **sets of assertion names per severity** (`check` gating, `target` tracked, `note`
advisory) and fails on an **unacknowledged removal or demotion** (`check` -> `target`/`note`), while
reporting additions and promotions (`target` -> `check`) as information. A legitimate rename is
allowed but must be *written down* in `scripts/probe-gate-acks.json` with a reason — deliberate
friction, so no assertion vanishes without a sentence saying why. Read that file's entries when you
review the diff; each one cites who verified it and where.

Two honest limits, so nobody over-trusts it: loop-generated assertion names collapse into one entry
per family, so it detects *a family disappearing*, not *one iteration of it*; and dynamically built
names cannot be compared at all (the script counts those and says so). It narrows a reviewer's search
— it does not replace the reviewer.

### The live gates must run against a non-UTC database (issue #53)

A clock or time-zone bug cannot show up when the author's database, API and test runner all sit in
UTC — PR #52 shipped a queue that expired every command on any other host and its gates were green.
Before claiming `qa-probe` / `e2e` green, set the test database to a non-UTC zone once:

```sql
ALTER DATABASE familyshield SET timezone = 'Asia/Dubai';   -- then reconnect / restart the API
SHOW timezone;                                             -- must print Asia/Dubai
```

Raw SQL rule that follows from it: never compare a column to `NOW()`; bind the instant from
application code (`${new Date()}`) and declare time columns `@db.Timestamptz(3)` in Prisma.

### Workflow trap: `secrets` in `if:`

A step or job `if:` that references `secrets.*` makes GitHub reject the entire workflow file. The only
symptom is a failed run **named after the file path** (`.github/workflows/ci.yml`) with zero jobs, while
`workflow-lint` (a separate file) stays green. `scripts/check-workflows.mjs` now reports it as an error.
Pattern to use instead: put the secret in `env:` and test the variable inside the `run:` body.

**In CI:** the `probe-integrity` job in `.github/workflows/ci.yml` runs this on every pull request
(`--base origin/<base branch> --head HEAD`, acks read from the PR's merge ref) and fails the PR on a
removed or demoted assertion. It runs unconditionally rather than behind a path filter, so a PR that
does not touch the probe shows the job green on a no-op comparison instead of absent.
