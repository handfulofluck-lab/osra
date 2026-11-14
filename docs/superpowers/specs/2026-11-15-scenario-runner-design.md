# Real-device scenario runner design (#667)

## Status and authorities

- **Status:** design for review, not an implementation or readiness claim.
- **Issue:** #667 and the merged `docs/QA/SCENARIO-SUITE.md` §2 and §4 step 2.
- **Safety:** the issue's command refusals are mandatory. No physical device, lease, backend, account, credential, secret or production action is used to create this design or its local tests.
- **Execution:** inline by K31 after Claude approves this written design and a later implementation plan. Fail-first Pester tests precede each production task. No subagent is substituted for the requested K3.1 Pro review.

## Outcome

`scenario.ps1` executes one small JSON scenario manifest through the same five stages on every run: preflight, before-values, evidence, steps, and restoration/report. A person must not retype setup or cleanup commands. A missing measurement is `NOT RUN`, never `PASS`. Every exit path attempts restoration and lease release, including a refused step, thrown error or Ctrl-C.

The implementation has no phone requirement for its tests. `-DryRun` performs the complete flow through a fake `adb` on `PATH`, a fake HTTP boundary and a fake lease store. It records calls and returns controlled values, so CI sees the same branches as a device run without claiming device evidence.

## Existing boundaries to reuse

- `phone-claim.ps1` owns the actual lease. The runner invokes it for claim, heartbeat and release with an explicit owner/purpose and `LeftState`; it does not create another lease protocol.
- `classify-build.ps1` supplies `Get-BuildKind`. A `test-only` or `debuggable` build cannot be labeled gate evidence; the report identifies the kind instead of silently upgrading it.
- The scenario catalogue supplies the story, pair, measurements and restore expectations. `scenario-family.mjs` remains the family seed/delete boundary; the runner does not duplicate account creation or secret handling.
- `workflow-lint.yml` already runs PowerShell self-tests. The new Pester suite and `scenario.ps1 -DryRun -Scenario SC-0.1` are added there with a nonempty-results assertion, not a new workflow. A green empty test discovery is not accepted.

## Manifest and schema

`scripts/hardware/scenarios/manifest.schema.json` is a draft-2020-12 schema with `additionalProperties: false` at every object. A manifest has:

- `id` (required, `SC-0.1` or `SC-1.1` for the committed samples), `title`, `pair`, `package`, `apiHealthUrl`, and optional `timeoutSeconds`.
- `steps` (required array): `adb`, `screencap`, `wait`, `http`, or `manual`.
- `measurements` (required array, possibly empty): `{ name, actual, comparator, limit }`. `actual` names a captured value; it is not free-form output from an arbitrary command.

Step fields are restricted by type:

- `adb`: `{ type, command }`, where `command` is an argument array, never a shell string. This prevents implicit shell evaluation.
- `screencap`: `{ type, name }`, using only an evidence-safe filename.
- `wait`: `{ type, seconds }`, an integer 0–3600.
- `http`: `{ type, method, path, body? }`, where method is `GET`, `POST`, `PATCH` or `DELETE`; path is relative to the manifest's backend base URL. The base URL and `apiHealthUrl` accept only loopback HTTP or `*.staging.osratech.com` HTTPS, with no userinfo, query, fragment or credentials.
- `manual`: `{ type, instruction }`, printed without any secret, and Enter is the only accepted continuation.

`measurements.comparator` is one of `eq`, `lte`, `gte`, `lt`, `gt`, `present`, `empty`. Each named actual must exist and have the expected scalar/array shape. `present` means a nonempty value exists; `empty` means an empty diff. Other comparators are numeric and have a numeric `limit`. A result is `PASS` only when every measurement has a value and passes, every step completed, and restore verified clean. A failed measurement is `FAIL`; missing, refused or unmeasurable data is `NOT RUN`; an unclean restore is `FAIL` with the original outcome preserved.

`SC-0.1.json` contains preflight, evidence, one trivial `screencap`, restore and one `empty` before/after-diff measurement, all satisfiable by the dry-run fake. `SC-1.1.json` contains `wait`, `screencap` and one illustrative `lte` measurement. It is a format example, not a device result or a claim that lock/unlock works.

## Runner architecture

`scripts/hardware/scenario.ps1` is the only production entry point. Small private functions in the same file cover argument/schema validation, safe subprocess invocation, evidence, measurement evaluation and reporting; no second runner or long-lived service is introduced.

Parameters are `-Scenario <id-or-path>`, `-Out <directory>` (default outside the repository), `-Owner <name>`, `-Serial <serial>` (default from the catalogue), `-Package <application-id>`, `-ApiBase <url>`, `-LeaseStore <path>` (test only), and `-DryRun`. The scenario ID resolves to `scripts/hardware/scenarios/<id>.json`; a direct path must stay under that directory or under `-Out`, preventing arbitrary file reads.

The flow is:

1. Parse and validate the manifest before claiming a lease or calling `adb`. Load schema rules and check step types, evidence names, URL hosts and forbidden commands.
2. Claim through `phone-claim.ps1`, check exact serial/model, classify the installed package and require the health URL to return success without logging its body.
3. Save app-ops `SYSTEM_ALERT_WINDOW`, `enabled_accessibility_services`, `accessibility_enabled`, the agent's app locale, `stay_on_while_plugged_in`, `accelerometer_rotation` and `user_rotation` verbatim, then create `<out>/<UTC timestamp>-<scenario id>/` with `before.json`, `runner.log`, `events.log`, step screenshots and `result.json`/Markdown.
4. Start `logcat -b events` through the same safe subprocess boundary, execute steps in order, capture named values, and heartbeat the lease during long waits. Never print message bodies, phone numbers, tokens, passwords, PINs, URLs with userinfo or command output that may contain them.
5. In `finally`, stop logcat, restore every saved value exactly, re-read all seven values and write before/after diffs, remove port forwards and uninstall only the manifest's test package when instructed by the scenario. Release the lease with the truthful `Clean`, `Locked` or `Unknown` state and write the report. Restoration failure takes precedence over any requested `PASS`.

Subprocesses receive argument arrays, not shell command strings. The runner never invokes `cmd /c`, `sh -c`, `Invoke-Expression`, or a manifest-provided script file. HTTP responses are status-checked and discarded except for declared nonpersonal measurement fields. Raw ADB output and HTTP bodies never enter `runner.log` by default.

## Mandatory refusals and data minimization

Validation rejects a command when any argument is or contains a forbidden operation:

- `date`, `cmd alarm set-time`, or `settings put global auto_time`;
- `dpm remove-active-admin`;
- `uiautomator dump`;
- `reboot`;
- `input text` whose argument is digits-only, because that is how an unlock code would be typed. Matching is structural, including nested `shell`/`exec-out` wrappers, not a brittle substring against the whole command line.

A `content query` step is refused unless the manifest explicitly sets `nonPersonal: true` **and** supplies an allowlist of nonpersonal projection columns. No phone-number or message-body column is allowed even when marked. There is no override for raw content output.

Every rule has a fail-first test and a named mutant: removing each forbidden-command check, allowing arbitrary file paths, skipping restore after an injected step exception, treating missing measurement data as PASS, accepting an empty before/after diff as the only success, emitting sensitive content, or allowing a test-only build to become gate evidence. Each mutant must turn its owning test red and the restored suite green.

## Evidence and result contract

`result.md` contains one row for the scenario: ID, `PASS`/`FAIL`/`NOT RUN`, measured value, limit, evidence folder, build kind, and restore result. `result.json` has the same values plus per-step exit codes, before/after diff, timestamps and lease-release result. No raw sensitive content is included. An empty table, missing result file or missing restore record fails the runner rather than silently succeeding. Screenshots are limited to OSRA surfaces and synthetic test data; real-family messages, notifications, account details and other apps' content are never captured as scenario evidence.

`scenario.ps1 -DryRun -Scenario SC-0.1` must print that table and exit 0. It also writes machine-readable evidence for tests. Other outcomes exit nonzero: invalid manifest/refusal `2`, scenario/measurement failure `1`, and unexpected infrastructure failure `1` with the refusal/restoration details. A `NOT RUN` caused by missing measurement data is nonzero so it cannot be mistaken for PASS.

The fake `adb` is a test fixture script on `PATH`, not production. It supports exact argument-array logging and canned before-values, screenshots, package dumps and logcat lifecycle. Fake `phone-claim` and HTTP responses use the same invocation contract and contain only synthetic data. No real lease, device state, account or service is touched.

## Implementation tasks for the later plan

1. Write Pester schema/refusal tests and make them fail, then implement manifest validation and the fake boundaries.
2. Add failing tests for preflight, before-values and evidence, then implement those stages.
3. Add failing tests for step execution, measurements, outcome classification and restoration, then implement the `finally` path and report.
4. Add the two manifests and prove the full dry run and every named mutant red to green. Wire Pester and dry-run assertions into `workflow-lint.yml`.
5. Run Pester, dry-run, `check-workflows.mjs --strict`, CI-path/self-tests, secret/docs guards and `git diff --check`. Document the exact results and explicitly leave physical execution to Claude's authorized slot.

## Documentation and review

The implementation PR includes this design, the implementation plan, a changelog fragment, `docs/TESTING.md` usage and safety notes, the roadmap scenario-runner status, and `docs/README.md` indexing. Claude verifies cross-family with the fake boundary and planted faults; Ahmed reviews exposure and secret handling if requested. No real-device PASS is claimed from Pester or dry-run evidence.
