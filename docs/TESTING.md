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
| Flutter | `cd apps/parent-app && flutter test` (+ `flutter analyze`) | Dashboard, rules editor, providers, layout at 320×568 | UI/contract regressions |
| Android JVM | `cd apps/child-android && ./gradlew testDebugUnitTest` | Rule engine, counters, monitored apps, HMAC signing logic | Agent logic regressions |
| Windows (xunit) | `cd apps/agent-desktop && dotnet test tests/FamilyShield.Agent.Tests` | Proxy/process/screen-time/tamper logic | Agent logic regressions |
| AI engine | `cd services/ai-engine && pytest tests -q` | Classifier + API smoke (skips what is absent) | Classification/API regressions |
| iOS | `.github/workflows/ios-ci.yml` (macOS runner) | SwiftPM build + simulator build | Swift compile/behaviour regressions |
| **Hardware** (device) | section 5 | Crash-loop, FGS start, location upload, overlays | Anything the emulator cannot show |

A green unit suite is **not** evidence that an invariant holds — that is what the probe is for. A green
probe is **not** evidence that a feature works on a phone — that is what hardware verification is for.

## 2. Prerequisites (dev machine)

| Need | Where it lives here |
|---|---|
| Node 20 + pnpm 9 | `C:\KARIM\tools\node` |
| PostgreSQL | Windows service `OSRA-Postgres` (auto-start) or `start-pg.bat` |
| Redis | `C:\KARIM\tools\redis\redis-server.exe --port 6379` |
| JDK 17 + Android SDK | `C:\KARIM\tools\jdk-17`, `C:\KARIM\tools\android-sdk` (`ANDROID_HOME` **must** be set, or gradle fails with "SDK location not found") |
| Flutter | `C:\KARIM\tools\flutter\bin` |
| .NET 8 SDK | `C:\KARIM\tools\dotnet` |
| Python 3.11+ | system python; AI tests need `services/ai-engine/requirements-dev.txt` |

Stack + secrets: `dist\start-backend.bat` starts Postgres/Redis/API and seeds the demo family. The
secrets it sets (`JWT_SECRET`, `INTERNAL_HMAC_SECRET`, `VAULT_KEY`) are required by the probe and e2e;
never commit them.

```bash
curl -s localhost:3000/health/deep     # {"ok":true,"db":"up","redis":"up"} — use this, not /health,
                                       # when apps misbehave: /health does not touch dependencies
```

## 3. Running the gates

```bash
cd services/api
INTERNAL_HMAC_SECRET=<from dist/start-backend.bat> VAULT_KEY=<same> node scripts/e2e.mjs      # 50/50
INTERNAL_HMAC_SECRET=<same> node scripts/qa-probe.mjs                                        # must be 0 failed
```

Also export `DATABASE_URL` in the shell that runs `e2e.mjs`: the erasure step then counts the child's
rows in Postgres itself (must be 0 in all 13 tables, ADR-0013) instead of printing a `NOTE` that the
count was skipped. The probe does not need it.

### Notification env (Phase 2a) — all optional

| Variable | Effect when set |
|---|---|
| `FCM_SERVICE_ACCOUNT_JSON` (JSON or base64) or `FCM_SERVICE_ACCOUNT_FILE` | Enables parent push via FCM HTTP v1 (Android, web, and iOS through Firebase). |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_ENV` | Enables direct APNs for native iOS tokens. |
| `PUSH_MIN_SEVERITY` (`info`\|`warning`\|`critical`, default `info`) | Severity floor; SOS and tamper always push. |
| `RESEND_API_KEY`, `EMAIL_FROM` | Enables real email. Without them emails are logged (dev) or a warning is logged (production); invites then echo `acceptToken` in dev only. |
| `APP_PUBLIC_URL` | Base URL used in reset/invite/digest links (default `http://localhost:3000`). |
| `DIGEST_HOUR_UTC` (default 18), `JOBS_ENABLED` (`0` disables the in-process scheduler) | Digest delivery schedule. The e2e/probe stacks should set `JOBS_ENABLED=0`. |
| `ROLLUP_HOUR_UTC` (default 2), `RETENTION_DAYS` (default 90, floor 7), `ROLLUP_RETENTION_DAYS` (default 365) | Phase 2c nightly usage rollup + retention (ADR-0013); same `JOBS_ENABLED` switch. External cron: call `runUsageRollup()` from `src/jobs/usageRollup.ts`. |
| `INTERNAL_SIGNING_ALLOW_V1` (default **off** since 2026-10-17; `1` opts in), `INTERNAL_SERVICE_CALLERS` (default `ai-engine`) | ADR-0014 signing v2: legacy body-only signatures are refused (`401 legacy_signature_disabled`, probe check J7) unless the operator sets `1` for a rollout whose agents still sign v1 — the probe then reports target J7 so the state is visible; the global secret works only as a named service caller. Agents' clocks must be within 5 minutes of the server's or every signed call is `401 stale_timestamp`. |

Running `e2e.mjs` and `qa-probe.mjs` back-to-back within one minute from one host trips the API's
200 req/min rate limit and every later check reads `429` — wait 60 s between runs; it is the limiter,
not the product.

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
| `ci.yml` | api · parent-app · child-android (`testDebugUnitTest` **and** `assembleDebug`) · agent-desktop · ai-engine |
| `ios-ci.yml` | The single iOS gate (SwiftPM build + `generic/platform=iOS Simulator`) |
| `workflow-lint.yml` | `scripts/check-workflows.mjs --strict` — a YAML file GitHub rejects means **zero jobs run**, so this is checked in its own file |
| `main-guard.yml` | Detects a commit on `main` that did not arrive through a pull request |

Local equivalent of the workflow lint (also installed as a pre-push hook by
`scripts/install-git-hooks.sh`):

```bash
node scripts/check-workflows.mjs --strict
```

## 5. Hardware verification (physical device)

Only the verifying agent does this, and only with the human's go-ahead — the phone belongs to a person.
`adb reverse` is the trick that makes it repeatable: the device reaches the API on *this* machine without
LAN or firewall changes.

```bash
export PATH="/c/KARIM/tools/android-sdk/platform-tools:$PATH"
adb devices -l                                  # confirm the intended device
adb reverse tcp:3000 tcp:3000                   # device can now reach http://127.0.0.1:3000
adb install -r apps/child-android/app/build/outputs/apk/release/app-release.apk
# pair with a code minted by the API, then verify what the build claims:
adb logcat -c && adb shell monkey -p com.familyshield.agent -c android.intent.category.LAUNCHER 1
adb logcat -d | grep -c "FATAL EXCEPTION"                       # must be 0
adb shell dumpsys activity services com.familyshield.agent      # isForeground=true types=0x8 (location)
adb logcat -d | grep "location/ping"                            # <-- 201 Created is the proof of upload
psql -c 'SELECT count(*) FROM "LocationPing"'                   # a row means it really persisted
```

Cover at minimum: **first run with no location permission** (must not crash), **grant → service starts
without relaunch**, **relaunch of a paired app** (service resumes), **a ping that reaches the API**, and
the specific claim the change makes. Paste the raw evidence into the issue.

**Clean up afterwards — always** (`AGENTS.md` §7):

```bash
adb uninstall com.familyshield.agent && adb reverse --remove-all
psql -h 127.0.0.1 -U familyshield -d familyshield -v apply=1 -f services/api/scripts/cleanup-test-data.sql
psql -c 'SELECT (SELECT count(*) FROM "Family"), (SELECT count(*) FROM "Child")'   # expect 1 / 1
node services/api/scripts/cleanup-test-redis.mjs            # dry run: lists orphaned per-device keys
node services/api/scripts/cleanup-test-redis.mjs --apply    # deletes only keys whose owner row is gone
```

**Redis is part of the environment too** — `AGENTS.md` §7 says persistent (`TTL -1`) keys must be
removed or explained, and the SQL script cannot see them. `cleanup-test-redis.mjs` reaps only keys
whose owning row no longer exists; it **never** touches a `revoked:device:*` key for a device that
still exists, because that key is the control that makes an unpaired device's 10-year JWT get `401`
(issue #56). Any key it reports as kept, keep.

## 5a. Tamper protection on hardware (ADR-0010, plan 1.1/1.2)

With the agent paired and a parent PIN set (the pairing flow asks for it), activate Device Admin from the
status screen (or, for a test, `adb shell dpm set-active-admin com.familyshield.agent/.security.FamilyShieldDeviceAdmin`).
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
#      the status screen shows "alert-only" and `adb uninstall` works again
```

**Lock that holds (plan 1.3):** with the agent paired and "display over other apps" allowed, send a `lock`
(parent app, or `POST /v1/devices/:id/command {"type":"lock"}`); the overlay appears. Then
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

`scripts/hardware/android-bypass-probe.ps1 -Serial <adb serial> -Port 3023 -StateFile <tr10-state.json>`
runs, against a paired phone with the PIN set and the test API reachable through `adb reverse`:
`adb uninstall` · `pm clear` · force-stop (the agent must come back by itself) · accessibility off ·
overlay revoked · Private DNS provider · escaping a lock (Home / Recents / Settings) · going offline
to dodge or escape a lock · VPN disconnected in Settings · device admin deactivated from Settings.
Each row is a measured outcome (what the OS answered, the alert's latency counted in Postgres, what the
status screen says) and the table it prints goes into the PR verbatim. Two rows need a human tap on
One UI (the VPN and device-admin screens never idle for `uiautomator`); the script says when.

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

| Symptom | Cause | What to do |
|---|---|---|
| Test counts look unchanged after a change | **Stale test XML** from a previous run (the suite never re-ran) | Check the timestamp of `app/build/test-results/...`; delete `app/build` and re-run |
| `BUILD FAILED: Unable to delete directory …build/tmp/kotlin-classes` | Windows file lock (indexer/Drive sync/daemon) | `./gradlew --stop`, delete the build dir, re-run; retry once before assuming a code error |
| `prisma generate` → `EPERM: rename …query_engine.dll.node` | A running API holds the engine DLL | Stop the API, generate, restart. If the API is not yours and you may not stop it, generate against a second checkout instead |
| The shared `:3000` API **refuses connections mid-session**, and its own log ends on `200`s with no stack trace | It was started inside an agent's task manager, and stopping a sibling task killed the process group — observed twice on the host PC (issue `#71`) | Do not host the shared API inside an agent task: start it detached (your copy of `start-backend.bat` — `docs/test-guides/start-backend.example.bat` ships in the repo — or `nohup … &` with output redirected). If you find it down, **say so on the board rather than starting a second instance** — the second start fails with `EADDRINUSE` and makes a healthy environment look broken. Then check the dead process's log: clean end = killed, not crashed |
| An API on a spare port answers `curl` with **nothing** and a Node script dies on `fetch failed` / `connect ECONNREFUSED ::1:<port>` — while `netstat` shows it **LISTENING on `0.0.0.0:<port>`** | The server bound IPv4 only, and `localhost` resolved to `::1` first on this host. It looks exactly like a dead server, which is why it reads as an outage | Use `127.0.0.1` in `API_BASE` (and in `curl`) for spare-port instances, or bind `::`. Bit me twice today: `qa-probe` exited 1 against a server that was up, and `curl http://localhost:<port>` returned empty |
| "Gates green" but nothing ran | Pipe masking: `cmd \| tail` hides the real exit code | Check `${PIPESTATUS[0]}`, or grep the output for the failure |
| A workflow shows as failed with **0 jobs** | GitHub rejected the workflow file (schema), YAML parsers accept it | `node scripts/check-workflows.mjs --strict` |
| Connections fail for some apps after agent testing | WinINET proxy left on a dead `127.0.0.1:8877` (and the `Connections` blob survives `reset-proxy.bat`) | See issue `#32`; delete the `Connections` values after resetting. Set `FS_SET_SYSTEM_PROXY=0` for developer machine test isolation; `reset-proxy.bat` now flushes WinINET immediately |
| Emulator: no location, ever | Emulator GPS injection does not reach agents | Verify location on the physical device only |
| CI: `Process completed with exit code 126` | A committed script lacks the executable bit in git (Windows-authored repos strip it) | `git update-index --chmod=+x <file>`; check both `gradlew` wrappers, `.sh` scripts and `.githooks/*`. This bit `gradlew` (the Android job) and the pre-push hook itself — on a Linux/macOS clone the hook would not have run at all |
| A running API dies right after you regenerate the Prisma client | `prisma generate` rewrites the client files the running process has loaded | Treat "migrate + generate" as a restart-and-start sequence: stop the server, `prisma generate`, start it. The deploy scripts do this for you; doing it by hand under a live server will kill it |
| API refuses to boot with `[SchemaDrift] …` | `assertPrismaClientInSync` comparing the generated client against the database (by design — issue #47) | Run what it tells you: `pnpm --filter @familyshield/api exec prisma migrate deploy && pnpm --filter @familyshield/api exec prisma generate` |
| `PrismaClientValidationError: Unknown argument <field>` / `400 invalid_input` on writes right after a schema migration | Generated Prisma client predates the DB migration (`#47`) | Run `pnpm exec prisma generate` (or run `pnpm db:migrate` which now chains `deploy && generate`). The API boot check (`assertPrismaClientInSync`) fails fast on schema drift |
| `e2e.mjs` aborts with `Error: ws timeout` and the summary never prints | **Not fully explained.** The old harness armed a one-shot promise on the socket and posted the alert the instant `open` fired, and an abort in that window records **0 FAILs**, so the remaining ~30 checks silently never run. My first hypothesis — the frame is published before the server registers the socket, which happens after the ticket's Redis `GET`+`DEL` — **did not reproduce**: 20/20 immediate-post trials delivered (TR-04 measurement, 2026-10-16) | The harness (TR-04) collects frames, re-posts the alert up to 3× if no frame arrives, and prints `frames=`, `wsError=` and `wsClose=` on failure — so the next abort is explicable instead of mysterious. Since TR-05 the gateway sends `{type:"ready", familyId, ts}` as the **first frame on every socket** (after it registers the socket) and the harness waits for it before posting the alert, replacing the Redis ticket polling; the probe asserts the contract (L1–L5). An alert lost **after** `ready` was received is a subscriber finding, not a race. See `services/api/scripts/e2e.mjs` §7. Read the line count, not just "no failures"; do not loosen the assertion |
| A committed cleanup script deletes more than expected | `cleanup-test-data.sql` restores the **database**; per-device Redis keys are invisible to it, and `revoked:device:*` is security state, not residue (`#56`) | Use `scripts/cleanup-test-redis.mjs` (dry run by default) rather than `redis-cli` by hand. Per-device keys are only ever deleted with their owner row. Since TR-05 `revoked:device:*` is written with `EX` = the device-token lifetime (`DEVICE_TOKEN_TTL_SECONDS`, 10 y) and `refresh:index:*` re-arms a 30 d TTL on every login — bounded, never reaped: a key that still has `TTL -1` predates the fix and gets its bound on the next write to it |
| `git push` hangs with **no output** and never returns | Git Credential Manager (`credential.helper=manager`) waiting on an interactive prompt in a non-TTY shell — `git fetch` on the same remote still works, which makes it look like a network problem | Supply the credential non-interactively for that one command: `git -c credential.helper='!f(){ echo username=x-access-token; echo password=$GH_TOKEN; }; f' push origin <branch>` with `GIT_TERMINAL_PROMPT=0`. Observed 2026-10-16 on the host PC; a `git fetch` in the same shell had just succeeded |

## 7. Definition of done (tests)

A change is done when **all** of these are true (`AGENTS.md` §3): the API unit suite is green, the probe
is green **including the new checks for the behaviour you changed**, e2e is green, the platform suites
for what you touched are green, a test exists that *failed before* the fix, and the docs (changelog,
ADR if the decision was architectural, this guide if the procedure changed) are updated.

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
