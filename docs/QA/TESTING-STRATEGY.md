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
5. **Verification sign-off before merge** for `sev:critical`/`sev:high`: the verifier comments with raw
   evidence on the PR. Below that, the author's own gates suffice.
6. **Stacked PRs: verify the tip** (it covers its ancestors) and re-verify after any rebase.
7. **Escalate to the human** after 24h blocked, or immediately on a second disagreement.

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
