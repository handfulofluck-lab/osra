# Testing & verification strategy

How implementation and verification are split, what each gate is for, and **the environments a change must
survive before we call it done**. Agreed between the implementing agents and the verifying agent; changes to
this document are themselves reviewable.

For *how to run* each gate see [`../TESTING.md`](../TESTING.md); for *why* they exist see
[`../adr/0005-adversarial-acceptance-gate.md`](../adr/0005-adversarial-acceptance-gate.md) and
[`../adr/0007-engineered-process-controls.md`](../adr/0007-engineered-process-controls.md).

## 1. Layers and ownership

| Layer | Owner | Catches | Cannot catch |
|---|---|---|---|
| Unit / platform suites | the author | regressions in logic you just wrote | wiring, environment, adversarial input |
| **Adversarial probe** (`services/api/scripts/qa-probe.mjs`) | **verifier** | a broken invariant, a missing ownership check, a gate that does nothing | anything not yet asserted in it |
| Live e2e (`services/api/scripts/e2e.mjs`) | both | wiring against a real stack, contract drift | environments other than the one it ran in |
| Platform suites (Flutter/JVM/xUnit/pytest) | the author | per-client behaviour | cross-platform assumptions |
| **Hardware** (physical device) | **verifier** | crash-loops, permission flows, GPS/FGS reality | — |

A green unit suite is **not** evidence that an invariant holds; a green probe is **not** evidence that a
feature works on a device. Each layer answers a different question.

## 2. The environment matrix (why we keep finding "works on my machine")

A change is verified when it has survived **at least one environment that differs from the author's** along
the axes that could plausibly matter. In practice, rotate through these:

| Axis | Why | How to exercise |
|---|---|---|
| **Timezone ≠ UTC** | `NOW()` vs `timestamp without time zone` compares local against UTC — passes only in UTC (issue #53) | set the DB session/user `timezone` (e.g. `Asia/Dubai`) or `PGTZ` for the gate run |
| Fresh DB from zero migrations | incremental DBs hide ordering/idempotency bugs | `createdb` scratch + `prisma migrate deploy` |
| Stale generated Prisma client | a schema change only works after `generate` (issue #47) | check out, migrate, **do not** generate, start |
| Cleared build outputs | "works because my `dist/` is warm" | `rm -rf dist build .dart_tool bin obj` |
| No credentials configured | push/email/HTTPS-inspect must no-op loudly | run with the env vars unset |
| Rate-limit windows separated | back-to-back gate runs produce 429s that look like failures | sleep a minute, or run gates in isolation |
| OS paths | exec bit, file locks, CRLF, `\` vs `/` | Windows + Linux/macOS (CI) |
| Emulator vs device | GPS injection, FGS start, permission dialogs | the physical phone, with `adb reverse` |

If an axis is not exercisable here, say so explicitly in the PR/issue ("verified on X, not verified on Y")
rather than implying coverage.

## 3. Rules both sides hold

1. **A new route or input ⇒ an adversarial check.** Assert the *rejection* (other family, revoked consent,
   bad signature, out-of-range, unknown enum) and add a happy path to e2e.
2. **Gates may only be extended.** Promoting a `note`/`target` to a hard `check` is welcome; removing an
   assertion requires the failing-first evidence and the replacement in the same diff. Never loosen a check
   to make a run green — if a check is wrong, fix the check explicitly and say why.
3. **"Green" must mean it ran.** Four variants of a gate that looks present and does nothing were found in
   one week: an invalid workflow file (zero jobs), a retired runner (queued forever), a step that swallows
   failures (`|| echo`), and an `if:` that skips. Check the steps, not the tick.
4. **Every claim carries its scope**, including corrections of earlier conclusions.
5. **Verification sign-off before every merge, by someone other than the author** (`AGENTS.md` §6.5,
   architecture decision 2026-10-17): the verifier comments with raw evidence on the PR. Severity sets
   the depth, not whether it happens: `sev:critical`/`sev:high` and hardware rows get the full gate re-run;
   docs-only changes get a line-by-line read plus the link check. (Superseded: "below `sev:high` the
   author's own gates suffice", which contradicted §6.5 once the lead became the only merging agent.)
6. **Stacked PRs: verify the tip** (it covers its ancestors) and re-verify after any rebase.
7. **Escalate to the human** after 24h blocked, or immediately on a second disagreement.

## 3a. Amendment **accepted** 2026-10-18 — hardware probe row 3 (`am force-stop`): the server notices the silent device

**Status: ACCEPTED — 2026-10-18, Claude (architecture), PR #127 comment 13:47:54Z.** Probe row 3 asserts
the accepted wording below, and `scripts/hardware/android-bypass-probe.ps1` implements it (2026-10-19,
TR-22, measured on the Flip4; the result is in `docs/QA/TEST-REQUESTS.md`). The old expectation — the agent
back within 120 s — is still measured and printed by the script as a **NOTE**, not as a pass or a fail,
because Android cannot meet it (evidence below). `AGENTS.md` §4 still governs the next change to this row:
fix it explicitly, with the evidence, and let the human decide — never by quietly retitling it.

**The row before the amendment (kept as history).** `scripts/hardware/android-bypass-probe.ps1`, row 3 as
it stood in TR-21: `am force-stop` the agent, then require its pid back within 120 s. It was a gating row,
so red meant red probe.

**What it measured on hardware, and why no code change can pass it.** TR-21 ran it on the Flip4
(`R5CW116Y6GF`, SM-F721B, Android 16) at `main@7435592`:

```text
17:24:54.926 pid before: 10790
17:26:56.135 row 3 force-stop -> came back=False after 121 s; pid= => FAIL
```

(raw log `C:\KARIM\tr-kimi\hw-2026-10-18\rows-1-3.log`, result table `RESULTS.md`; the pid came back only
when the app was launched — `17:27:04.586 relaunch pid=13330`). Android puts a force-stopped package in
the **stopped state**: no broadcast, alarm, job or accessibility rebinding is delivered until a user
launches the app or the device reboots. The agent cannot restart itself, so "back within 120 s" is not a
requirement any change can meet; the row would stay red forever, and a permanently red row teaches the
next tester to ignore the probe.

**The row's intent, restated.** The threat it was written for is *the server stops hearing from the device
and the parent is never told* — a **silent device**. That intent is measurable, and it is what the row
asserts now.

**Evidence that the intent is reachable — the alert fires.**
- **#124** (`4c41a07`, 2026-10-18): `src/jobs/deviceSilence.ts` matched `status = "active"`, a value no
  writer produces (`packages/shared-types` and every writer use `online`/`offline`/`locked`/`sos`), so the
  watch never raised anything at all. It matches `online` now, and `test/device-silence.test.ts` drives a
  **real telemetry POST** into `runDeviceSilenceCheck(now, env)` with a backdated `lastSeen`, asserting one
  critical `tamper`/`device_silent` alert per episode and the flip to `offline`.
- **#150** (`4adc601`, 2026-10-18): the live half is gated — probe `G22` (a real telemetry POST reads back
  `status:"online"` with a fresh `lastSeen`, the value the watch matches) and `G23` (every status written
  is inside the shared vocabulary); the run reported 130 passed / 0 failed. The *timing* half stays a unit
  test because the watch has no HTTP trigger and the probe deliberately has no `DATABASE_URL`
  (`docs/TESTING.md` §6). (#149, merged the same day, is the digest-claim fix: it bears on neither the
  silence alert nor this row, and is not part of this evidence.)
- **#127 comment** (Claude, 2026-10-18 13:47:54Z) is the architecture decision on what the row *means*,
  and it is the acceptance this section records.
- **TR-22** (2026-10-19) is the first hardware measurement under the new definition: the Flip4 was
  force-stopped against an API started with `JOBS_ENABLED=1` and `DEVICE_SILENT_MINUTES=5`, and the
  `device_silent` alert arrived through the real elapsed window (numbers in `docs/QA/TEST-REQUESTS.md`).

**The accepted row — replace the assertion, keep the row.** Verbatim:

> After `am force-stop`, wait one silence window (`DEVICE_SILENT_MINUTES`, default 30, floor 5) plus one
> 5-minute tick, then require: exactly **one** critical alert with category `tamper` / type
> `device_silent` for the device, and `Device.status = "offline"`.

That is PASS or FAIL from Postgres, and it is the property the parent actually depends on. Backdating
`lastSeen` in the database would measure the job, not the product, so the probe waits the real elapsed
window; a 5-minute window is acceptable for this gate row, and a run records in the row's evidence which
window it used.

**Amendment (#166, 2026-10-19) — the quote above stays as accepted; the floor it names moved.** A
5-minute window equals the agent's stationary ping (`LocationService.kt:430`) and is shorter than one
telemetry interval (`WorkScheduler.kt:48`), so a healthy phone could be flagged between reports. The
server now clamps `DEVICE_SILENT_MINUTES` to the safe minimum 30 (two telemetry intervals) and warns at
boot; the **test-only** `DEVICE_SILENT_ALLOW_TIGHT=1` keeps the old 5-minute floor for this row and logs a
loud warning. The row's assertion — one alert, `Device.status = "offline"`, real elapsed window — is
unchanged; `docs/TESTING.md` §5f carries the command.

Two further rows #127's decision proposes are kept separate, so each can be argued on its own:
- **row 3b** — force-stop *then* `adb reboot`: the agent must be running again within 60 s of boot. This
  one *is* a self-recovery requirement and it waits on #128's `BootStartPolicy` fix (landed; not yet
  measured on hardware).
- **a tamper row** — the child can reach the same state from Settings ▸ App info ▸ Force stop; the
  accessibility service should treat our own App-info page as a protected screen (leave within 1 s, raise
  `tamper_attempt`). Not gate-blocking yet, and no issue exists for it (#127 asked for one).

**What stays true either way.** The adb route is a *host* route, not a child route — no child can run
`am force-stop`. So row 3 guards "an agent that died and nobody noticed", not "a child stopped the agent".
Had the amendment been rejected, row 3 would have stayed FAIL and the probe red: that is the honest state,
and the alternative is not a green row but a deleted one, which §3 rule 2 and `AGENTS.md` §4 forbid.

## 4. Cadence and where messages go (agreed 2026-10-16)

- **Interval (shortened 2026-10-17 at the maintainer's request):** while any request in
  `docs/QA/TEST-REQUESTS.md` or any work order is open, everyone checks every **15 minutes**; with
  nothing open, every **30 minutes**. (Superseded: 30 / 60 minutes, agreed 2026-10-16.)
- **The message file is `docs/QA/TEST-REQUESTS.md`:** short, dated messages in its *Messages* section
  (newest first), one line each, quoting a `TR-nn` where one applies. Long-form evidence and
  point-by-point replies stay in `DISCUSSION-LOG.md` (append-only); PR comments carry the evidence for a
  specific change; the program board issue (#50) is the source of truth for lanes and ownership.
- The author responds in the same window with agreement, a counter-proposal, or the fix — the loop is
  two-way, not a queue.
- If the interval must change (long build, night off), say so — silence should not read as agreement.

## 5. Sign-off checklist for a merged change

- [ ] Unit/platform suites green for what changed, and a test exists that **failed before** the fix.
- [ ] `qa-probe` green **including a new check for the changed behaviour**, with no weakened assertions.
- [ ] Live `e2e` green, run in isolation (not in the rate-limit shadow of another gate).
- [ ] Verified in at least one **non-author environment** from the matrix in §2.
- [ ] CI actually ran the relevant jobs (steps inspected, not just the tick).
- [ ] Docs updated in the same PR: `CHANGELOG.md`, an ADR for an architectural decision, `TESTING.md`/
      this file when a gate or procedure changes.
- [ ] Test data cleaned (seeded DB state) and no stray processes left behind by the verification run.

## 6. Anti-patterns we have actually hit (kept as a checklist, not a lecture)

| Anti-pattern | What it looked like |
|---|---|
| Green because mocked | the Prisma client was stubbed, so a real-DB validation error was invisible (#47) |
| Green because stale | test XML from four days earlier; the suite never re-ran |
| Green because unrun | invalid workflow (0 jobs), retired runner, swallowed failure, `if:` skip |
| Green only in UTC | the command queue expired everything outside UTC (#53) |
| Gate that cannot fail | `|| echo` at the end of an iOS test command |
| Author's-machine-only | a client generated locally, or a build output that was already warm |
| Deploy path ≠ dev path | `migrate deploy` without `generate`; the tester launcher would 400 on child creation |
