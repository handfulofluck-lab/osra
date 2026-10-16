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

## 6. Traps that have cost real time here

| Symptom | Cause | What to do |
|---|---|---|
| Test counts look unchanged after a change | **Stale test XML** from a previous run (the suite never re-ran) | Check the timestamp of `app/build/test-results/...`; delete `app/build` and re-run |
| `BUILD FAILED: Unable to delete directory …build/tmp/kotlin-classes` | Windows file lock (indexer/Drive sync/daemon) | `./gradlew --stop`, delete the build dir, re-run; retry once before assuming a code error |
| `prisma generate` → `EPERM: rename …query_engine.dll.node` | A running API holds the engine DLL | Stop the API, generate, restart |
| "Gates green" but nothing ran | Pipe masking: `cmd \| tail` hides the real exit code | Check `${PIPESTATUS[0]}`, or grep the output for the failure |
| A workflow shows as failed with **0 jobs** | GitHub rejected the workflow file (schema), YAML parsers accept it | `node scripts/check-workflows.mjs --strict` |
| Connections fail for some apps after agent testing | WinINET proxy left on a dead `127.0.0.1:8877` (and the `Connections` blob survives `reset-proxy.bat`) | See issue `#32`; delete the `Connections` values after resetting. Set `FS_SET_SYSTEM_PROXY=0` for developer machine test isolation; `reset-proxy.bat` now flushes WinINET immediately |
| Emulator: no location, ever | Emulator GPS injection does not reach agents | Verify location on the physical device only |
| CI: `Process completed with exit code 126` | A committed script lacks the executable bit in git (Windows-authored repos strip it) | `git update-index --chmod=+x <file>`; check both `gradlew` wrappers, `.sh` scripts and `.githooks/*`. This bit `gradlew` (the Android job) and the pre-push hook itself — on a Linux/macOS clone the hook would not have run at all |
| `PrismaClientValidationError: Unknown argument <field>` / `400 invalid_input` on writes right after a schema migration | Generated Prisma client predates the DB migration (`#47`) | Run `pnpm exec prisma generate` (or run `pnpm db:migrate` which now chains `deploy && generate`). The API boot check (`assertPrismaClientInSync`) fails fast on schema drift |
| `e2e.mjs` aborts with `Error: ws timeout` and the summary never prints | The harness posts the alert the instant the socket reports `open`, while the server registers the socket inside the async route only after the ticket's Redis `GET`+`DEL` — under load the message is published before registration and is lost | Re-run it (observed once in two consecutive runs, on a loaded host). Note it aborts the run with **0 FAILs recorded**, so the remaining ~30 checks silently never execute — read the line count, not just "no failures". QA owns the harness fix; do not loosen the assertion |
| A committed cleanup script deletes more than expected | `cleanup-test-data.sql` restores the **database**; per-device Redis keys are invisible to it, and `revoked:device:*` is security state, not residue (`#56`) | Use `scripts/cleanup-test-redis.mjs` (dry run by default) rather than `redis-cli` by hand. Per-device keys are only ever deleted with their owner row |

## 7. Definition of done (tests)

A change is done when **all** of these are true (`AGENTS.md` §3): the API unit suite is green, the probe
is green **including the new checks for the behaviour you changed**, e2e is green, the platform suites
for what you touched are green, a test exists that *failed before* the fix, and the docs (changelog,
ADR if the decision was architectural, this guide if the procedure changed) are updated.

### Workflow trap: `secrets` in `if:`

A step or job `if:` that references `secrets.*` makes GitHub reject the entire workflow file. The only
symptom is a failed run **named after the file path** (`.github/workflows/ci.yml`) with zero jobs, while
`workflow-lint` (a separate file) stays green. `scripts/check-workflows.mjs` now reports it as an error.
Pattern to use instead: put the secret in `env:` and test the variable inside the `run:` body.
