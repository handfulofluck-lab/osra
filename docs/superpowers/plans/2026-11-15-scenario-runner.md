# Real-device Scenario Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a safe, manifest-driven scenario runner with a no-device dry run, evidence, truthful results and guaranteed restoration.

**Architecture:** One PowerShell entry point validates every step before claiming a lease, then uses small injected process, HTTP and lease boundaries. Argument arrays and structural command checks prevent shell interpretation and device-connection changes. A fake `adb` exercises the same orchestration in CI; no test or dry run claims physical-device evidence.

**Tech Stack:** PowerShell/Pester, JSON Schema draft 2020-12, existing `phone-claim.ps1` and `classify-build.ps1`, Node built-ins only where needed by the fake, .NET built-in compression APIs for PNG cropping. No new package dependency.

**Spec:** `docs/superpowers/specs/2026-11-15-scenario-runner-design.md`, #667, `docs/QA/SCENARIO-SUITE.md` §2/§4 step 2, Claude's five design additions at 2026-11-14 21:24Z and four implementation additions at 2026-11-15 05:01Z in PR #797. Native inline execution by K31 is selected in the approved design; the plan is approved at `36ccb97b` with these four additions folded in.

## Global Constraints

- No physical phone, lease, real account, production, store, credential or real-family data is used in implementation or tests. Never merge or enable auto-merge.
- The runner always injects `adb -s <serial>` itself. Every element is split on whitespace before checking and shell metacharacters (`; & | $ ` > <`) are refused, because one `shell` element reaches the phone as a command line (#797 review, item 2). Refuse `-s`, `-t`, `-H`, `-P`, `connect`, `disconnect`, `tcpip`, `usb`, `kill-server`, `reconnect`, `svc wifi|data|bluetooth`, `cmd wifi`, `cmd connectivity`, `settings put global airplane_mode_on` and `am broadcast … AIRPLANE_MODE`, including nested `shell`/`exec-out` forms. Never drop the wireless link.
- Refuse `date`, `cmd alarm set-time`, the `settings` keys `auto_time`, `auto_time_zone` and `time_zone`, every `dpm` verb other than `list-owners`, `uiautomator dump`, `reboot`, `reboot-bootloader`, `root`, `remount`, `sideload`, top-level `install`/`uninstall`, `wm` changes, `input text` containing a run of 4+ digits (including digits split across elements), `input keyevent 111`/`KEYCODE_ESCAPE`, digit-keycode sequences 7–16 or `KEYCODE_0`…`KEYCODE_9` (including a run followed by ENTER), and `pm uninstall`/`pm clear` of an active admin package. Check admin ownership through read-only `dpm list-owners` or `dumpsys device_policy` immediately before allowing a removal.
- Read `dumpsys window`/`trust` during preflight and save lock state. A manual step requiring an unlocked phone stops `NOT RUN`; never type or request an unlock code.
- Capture only `exec-out screencap -p` bytes in memory, never an on-device path. Crop to the OSRA window, excluding status bar and notification shade. Uncropped bytes never reach disk on either side; missing safe bounds is `NOT RUN`, never permission to capture the whole screen.
- Save and restore all nine values: the original seven plus `screen_off_timeout` and `zen_mode`, each read and written in its own settings table (`secure` for the accessibility keys, `system` for `screen_off_timeout` and the rotation keys, `global` for the rest) (#797 review, item 3). Restore in `finally` on every exit path, including refusal/error/Ctrl-C, and release with truthful `Clean`/`Locked`/`Unknown`. Heartbeat the lease before each step and stop with `scenario_timeout` when `timeoutSeconds` is exceeded.
- A dry run refuses to start unless `adb` resolves inside `scripts/hardware/tests/fixtures/bin`, so a developer PC with the phone attached cannot drive the real device without a lease (#797 review, item 4).
- Raw command output and HTTP bodies do not enter logs. `content query` requires `nonPersonal: true` and an explicit safe projection allowlist; phone numbers/message bodies are never permitted.
- Missing measurements are `NOT RUN`; an empty diff alone is not PASS. Restore failure overrides PASS. Dry-run evidence is marked as such.

## Review Focus

- Hidden nested connection commands could drop the shared test phone — Task 1 tests wrappers and every banned verb, with each refusal removed as a named mutant.
- A package may become an active admin between validation and removal — Task 2 checks current ownership immediately before removal and tests that transition.
- A locked phone or unknown window bounds could expose other apps/notifications — Tasks 2 and 3 prove refusal without producing an image.
- Restore/release may fail while a step is already failing — Task 4 preserves the original outcome and forces a non-pass result with both errors recorded.
- Cropping may silently change PNG semantics or dimensions — Task 3 uses fixed binary RGB/RGBA fixtures and independently checks pixels/dimensions; unsupported PNG forms are `NOT RUN`.

### Task 1: Manifest contract and structural refusals

**Files:**
- Create: `scripts/hardware/scenario.ps1`
- Modify: `scripts/hardware/scenarios/manifest.schema.json`
- Create: `scripts/hardware/tests/Scenario.Validation.Tests.ps1`
- Create: `scripts/hardware/tests/fixtures/bin/adb` and `adb.cmd`

**Interfaces:** `Read-ScenarioManifest(path)` returns a validated manifest. `Invoke-ScenarioProcess(exe, args)` accepts only an executable and argument array. ADB steps contain `command: string[]`, optional `nonPersonal` and `projection: string[]`.

- [ ] Write fail-first schema tests for unknown fields/types, invalid paths/URLs and all five step shapes. Add a table driving every forbidden operation, including nested wrappers, digit keycode sequences/names, 4+-digit text runs, clock keys, `wm size`/`wm density`, and all connection-changing verbs (`svc`, `cmd wifi`/`connectivity`, and airplane-mode commands included). Name the single check removed for each row.
- [ ] Run `Invoke-Pester scripts/hardware/tests/Scenario.Validation.Tests.ps1 -Output Detailed`; expect failures because the entry point/schema rules do not exist.
- [ ] Implement validation before any lease/ADB call, with schema `additionalProperties: false` throughout. Use exact argument-array invocation; never `Invoke-Expression`, `cmd /c`, `sh -c` or a manifest script. Validate safe `content query` declarations and discard all other raw output. Allow `settings put` only for one of the nine saved keys.
- [ ] Implement the fake `adb` launchers with exact argument logging, canned safe values, controlled failures and no real ADB fallback.
- [ ] Rerun validation tests green. Commit the tested slice with the K31 trailer.

### Task 2: Preflight, connection, lock state and saved state

**Files:**
- Modify: `scripts/hardware/scenario.ps1`
- Create: `scripts/hardware/tests/Scenario.Preflight.Tests.ps1`

**Interfaces:** `Invoke-ScenarioPreflight` calls the real lease helper, checks serial/model/build/health and lock state. `Get-ScenarioBeforeState` records the nine named settings verbatim. `Test-AdminPackageRemoval` reads current admin ownership before a removal.

- [ ] Write fail-first tests proving every ADB call starts with injected `-s <serial>`, manifests cannot inject their own, health bodies are discarded, test-only/debuggable builds are not gate evidence, and the lock state is in `before.json`.
- [ ] Test a locked phone with an unlocked-only manual step: result `NOT RUN`, no unlock/input command and no image. Test an active-admin `pm uninstall`/`pm clear`, including ownership changing after manifest validation; both are refused without removal. Test an unlisted `settings put` key and both `wm` mutations, proving nothing changes that is not restored.
- [ ] Implement lease claim/heartbeat/release calls, exact serial/model checks, build classification, URL health checking and read-only `dumpsys window`/`trust` parsing through the fake boundary.
- [ ] Save app-ops overlay, accessibility services/enabled, locale, stay-awake, accelerometer/user rotation, `screen_off_timeout` and `zen_mode` before steps. Evaluate admin ownership immediately before any permitted test-package removal.
- [ ] Run preflight and validation suites green. Commit with the K31 trailer.

### Task 3: Evidence and OSRA-only PNG crops

**Files:**
- Modify: `scripts/hardware/scenario.ps1`
- Create: `scripts/hardware/tests/Scenario.Evidence.Tests.ps1`
- Create: `scripts/hardware/tests/fixtures/*.png` (small synthetic binary fixtures)

**Interfaces:** `New-ScenarioEvidence` creates the timestamped evidence folder and sanitized runner log. `Save-ScenarioScreenshot` accepts only safe bounds and an evidence-safe name, writing a cropped PNG and dimensions. No full-screen fallback or on-device screenshot file exists.

- [ ] Write fail-first tests for path traversal, log redaction and missing/locked bounds. Using fixed non-interlaced RGB/RGBA PNGs, assert exact cropped width, height and known pixels; status-bar and shade rows must not survive. A skipped-crop mutant must make the height assertion red. Assert the fake `adb` log contains no on-device screenshot path.
- [ ] Implement private PNG crop functions using .NET compression APIs only: capture `exec-out screencap -p` into memory, parse supported Android-style PNGs, defilter/filter scanlines correctly, crop safe OSRA bounds, and reject interlaced/unsupported/corrupt images as `NOT RUN`. Never write uncropped bytes to disk on either side. Do not introduce an image package or Windows-only drawing dependency.
- [ ] Start/stop `logcat -b events` through the same process boundary; keep raw output out of `runner.log`. Create `before.json`, `events.log`, `result.json` and `result.md` only in the evidence folder.
- [ ] Run evidence tests plus prior suites green. Commit with the K31 trailer.

### Task 4: Steps, measurements and guaranteed restoration

**Files:**
- Modify: `scripts/hardware/scenario.ps1`
- Create: `scripts/hardware/tests/Scenario.Run.Tests.ps1`

**Interfaces:** `Invoke-ScenarioSteps` runs `adb`, `screencap`, `wait`, `http` and `manual` in order. `Get-ScenarioOutcome` implements `eq/lte/gte/lt/gt/present/empty`. `Restore-ScenarioState` and lease release run in `finally`.

- [ ] Write fail-first tests for every step kind, scalar/array measurement shapes, missing actual → `NOT RUN`, failed measurement → `FAIL`, and an empty diff never being the only PASS. Dry-run results must say they are not physical evidence.
- [ ] Inject a step exception, refusal and Ctrl-C: all nine values are restored and re-read, logcat stops, port forwards are removed, and lease release records truthful state. A failed restore overrides PASS; a failed release cannot disappear behind a step error.
- [ ] Implement ordered execution, declared-value capture, status-only HTTP handling, heartbeat during waits, and the `finally` restoration/report path. Manual steps are interactive only when unlocked and authorized; dry-run uses the fake, never a hidden prompt.
- [ ] Write result JSON/Markdown with per-step outcomes, measurements, limits, build kind, restore and release results; missing result/restore records fail the run. Preserve exit codes: refusal 2, scenario/measurement/infrastructure failure nonzero, successful SC-0.1 dry run 0.
- [ ] Run all Pester suites green. Commit with the K31 trailer.

### Task 5: Samples, CI wiring and documentation

**Files:**
- Modify: `scripts/hardware/scenarios/SC-0.1.json`, `SC-1.1.json`
- Modify: `.github/workflows/workflow-lint.yml`
- Modify: `docs/TESTING.md`, `docs/ROADMAP.md`, `docs/README.md`
- Create: `CHANGELOG.d/2026-11-15-scenario-runner.md`

**Interfaces:** CI runs Pester and `scenario.ps1 -DryRun -Scenario SC-0.1`, asserts nonempty test discovery and the printed table, and rejects a silent/empty green run.

- [ ] Complete the two small manifests: SC-0.1 exercises preflight/evidence/restore with an `empty` diff; SC-1.1 illustrates wait/screencap/lte without claiming device behavior. Validate both against the schema.
- [ ] Run the complete dry run and all Pester tests, then each named mutant one at a time, expecting RED before restoration and GREEN after.
- [ ] Add the tests/dry run to existing `workflow-lint.yml`, with explicit counts/result-file checks. Run `node scripts/check-workflows.mjs --strict` and affected workflow self-tests.
- [ ] Document usage/safety and current status, add the fragment and index both design and plan. Run docs links, conflict-marker, secret/PIN, brand and `git diff --check` guards. Commit with the K31 trailer.

### Task 6: Independent review handoff

- [ ] Review the entire branch against all five additions and update stale design/PR claims.
- [ ] Fetch and cleanly merge current `main` without rewriting history; rerun affected gates and ensure no test artifacts enter the PR.
- [ ] Push only `k31/667-scenario-runner`, update the existing PR #797 for #667, and request Claude's cross-family verification with the fake boundary and mutants. Leave physical execution to Claude's authorized lease slot. No auto-merge or K31 merge.
