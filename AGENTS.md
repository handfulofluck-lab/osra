# AGENTS.md — working agreement for AI agents in this repository

> Read this first. It is binding for every agent (Antigravity, Kimi Code, Copilot, Cursor, …)
> that touches this repo.

## 1. Roles

The split was re-cut by the maintainer on 2026-10-17. This table replaces the earlier one, in which
Kimi verified and Antigravity implemented; the principle survives the re-cut, enforced at the merge
instead (§6.5).

| Agent | Role | May do | Must not do |
|---|---|---|---|
| **Kimi Code** (development lead) | Implements features and fixes; owns `main` and releases | Edit application code, tests, CI and docs; open and **merge** PRs (§6.5); tag and prepare releases | Merge unverified work, **including their own**; merge with a red gate; push to `main` (§6); act on a store account, entitlement or key |
| **Claude** (KCL lead) | Owns architecture decisions; constructive testing with a detailed fix for every finding (§12) | Decide architecture and record it as an ADR; review designs and diffs against their roadmap row; verify TR rows; write tests, checklists and test requests | Merge; push to `main`; write product code |
| **Antigravity** (testing) | Testing: runs the gates, tests PR claims, runs the hardware rows | Read everything; re-run every gate on a branch; test each falsifiable claim; run hardware rows; file `TR-*` results with raw output | Merge; change the code under test to make a claim true; weaken or delete a failing check |
| Human maintainer | Product and security trade-offs; anything that needs an account or money | Everything; final call on scope | — |

**The principle: the author of a change is never its only verifier.** With one agent authoring and
merging, the separation moves from who holds the keyboard to who holds the evidence: Kimi may merge
their own work, but only against a verification record produced by another agent (§6.5). Where no other
agent can run a gate — a leased handset, a host only one machine reaches — the author's run is disclosed
as such and the row goes to the human or stays open; it does not quietly become verification.

## 2. The loop

1. **Design, when the change is architectural.** Claude records the decision as an ADR
   (`docs/adr/NNNN-*.md`, §8) and names the falsifiable claims a verifier should test. A design argument
   that is not in an ADR does not exist at review time (§6.3): the ADR is where alternatives and their
   costs are settled, and where a later reader finds why.
2. **Implement.** Kimi takes the item from the queue (`docs/QA/ANTIGRAVITY-INBOX.md`), works **on a
   branch** (§6), writes the test that fails before the fix (§3), runs the full local gate, and opens the
   PR with the template's restatement plus the raw gate output. The item's *Acceptance* line is the
   contract; normally that means the named `qa-probe` checks now pass.
3. **Verify — by another agent.** Antigravity re-runs the gates on the branch (not a re-read of the
   author's paste, §6.2), tests each falsifiable claim, and runs the hardware row where one applies,
   recording the measurement. Claude reads the design and the diff and may add a test or a checklist; a
   test Claude adds is evidence once Antigravity — or the maintainer, for a hardware row — has run it. The
   result is a `TR-*` row in `docs/QA/TEST-REQUESTS.md` with the raw output, and a point-by-point reply in
   `docs/QA/DISCUSSION-LOG.md`.
4. **Merge or return.** Kimi merges when §6.5 holds, citing the verification record in the merge message;
   otherwise the PR returns with the failing evidence and its `TR-*` row stays open. A returned PR is the
   gate working, not a verdict on the author.
5. **Release.** With `main` green and verified, Kimi prepares the release: version, `CHANGELOG.md` entry,
   artefacts, notes. Publishing to a store, an entitlement, a paid signing key or an API key is the human's
   step (§1) — the lead prepares, the human authorises.

## 3. Definition of done (every change)

- [ ] `services/api`: `pnpm --filter @familyshield/api test` green (193+ tests).
- [ ] `services/api`: `node scripts/qa-probe.mjs` green against a live stack — **no regressions,
      and the acceptance checks for your item now pass** (env: `INTERNAL_HMAC_SECRET`).
- [ ] `services/api`: `node scripts/e2e.mjs` still 50/50 against a live stack.
- [ ] Client suites green for the platform you touched:
      `apps/parent-app` → `flutter test` · `apps/child-android` → `./gradlew testDebugUnitTest`
      (`ANDROID_HOME` required) · `apps/agent-desktop` → `dotnet test` ·
      `services/ai-engine` → `pytest tests`.
- [ ] New/changed behaviour has a test in the same suite that failed before the fix.
- [ ] **Documentation is updated in the same PR** (§8): a `CHANGELOG.md` entry for anything
      user-visible, an ADR for an architectural decision, and `docs/TESTING.md` when the procedure,
      a suite or a gate changes.

## 4. Hard rules

- **Never** weaken a check, delete a failing assertion, or add a skip to make a gate green.
  If a check is wrong, say so with evidence and let the human decide.
- **Never** commit secrets, tokens, keystores, or built binaries (`dist/` is gitignored on
  purpose). Config examples use placeholders only.
- **Never** rewrite working code that a QA report marks "Verified solid" without a reason in
  the PR description.
- **Never** use the physical test phone without a held lease (§9), and never end a lease with a
  parental restriction (`lock`, `pause`, `pause_internet`, ring) still applied.
- Preserve the security invariants: family isolation (403), consent gate (428), per-device HMAC
  agent auth, device revocation on unpair, refresh rotation, optional MFA.
- Findings are evidence-based: file:line + repro + expected/actual. "Seems risky" is not a bug.

## 5. Where things live

| Path | Purpose |
|---|---|
| `docs/QA/QA-REPORT-<date>.md` | Consolidated QA state (Kimi-owned) |
| `docs/QA/audits/*.md` | Raw per-platform audits (read-only, Kimi-owned) |
| `docs/QA/ANTIGRAVITY-INBOX.md` | The ordered work queue (Kimi writes, Antigravity works through) |
| `docs/QA/DISCUSSION-LOG.md` | The durable, full-detail dialogue between the agents (append-only) |
| `services/api/scripts/qa-probe.mjs` | Adversarial acceptance gate (must pass before merge) |
| `services/api/scripts/e2e.mjs` | Happy-path acceptance flow |
| `scripts/hardware/phone-claim.ps1` | The lease over the one physical test phone — claim before `adb`, release with the state you hand over (§9) |
| `CHANGELOG.md` | What changed, when, in which PR — with the verification state |
| `docs/README.md` | Documentation index (start here when looking for anything) |
| `docs/TESTING.md` | How to run every suite/gate, read failures, and verify on hardware |
| `docs/adr/` | Architecture decision records — reasoning, alternatives, costs |
| `docs/test-guides/` | Tester-facing documentation |
| `docs/SPEC*.md` | Product/API specification |

## 8. Documentation is part of the deliverable

Code without the reasoning behind it is a liability for the next person (or agent). So every change
carries its documentation **in the same PR**:

- **`CHANGELOG.md`** — any user-visible change (feature, fix, behaviour, dependency, CI gate). Include
  the PR/issue number and, where relevant, the measured evidence. If something could not be verified
  where you wrote it, **say so** — an unqualified "fixed" is a documentation bug.
- **`docs/adr/NNNN-*.md`** — an architectural decision, or a decision that closes off an option for the
  future. Record context, the decision, the reasoning, the alternatives you rejected and why, and the
  costs (including the bad ones). Never edit an accepted ADR to reflect a new decision: add a new one
  that supersedes it.
- **`docs/TESTING.md`** — when a suite, a gate, a procedure or an environment trap changes.
- **`docs/README.md`** — when a document is added or moves.
- **`README.md`** — when the product surface, suite list/status, security model or limitations change.
- **`docs/QA/`** — the verifying agent owns the report, the queue and the discussion log; the
  implementing agent answers in the log rather than rewriting the report.

**Writing rules.** Prefer the concrete over the general (a command, a status code, a `file:line`); state
what you verified and where; keep the *why* next to the *what*; and never delete a record of a past
state — supersede it. A reviewer may ask for documentation changes the same way they ask for code
changes.

## 6. Landing changes — `main` is protected, no direct pushes

**Every change reaches `main` through a pull request**, including docs, QA reports and one-line
fixes. Nobody (agent or human) pushes to `main` directly. This exists so the author of a change is
never the one who decides it is correct.

**Branch names:** `qa/<topic>-<date>` (Kimi) · `fix/<item-id>-<topic>` or `feat/<topic>` (Antigravity).

### 6.1 A PR is a discussion, not an announcement

Fill in `.github/PULL_REQUEST_TEMPLATE.md`. It requires, in order:

1. **Restatement of the requirement in the author's own words** — "I understand the ask as: …".
   *This is the single most valuable line in the PR*: misunderstandings get caught before code is
   written, not after. If the restatement is wrong, stop and re-discuss instead of reviewing the diff.
2. What changed and why, with `file:line` references.
3. **The exact gates you ran and their raw output** (`qa-probe`, `e2e`, the platform suites).
4. **What the reviewer must verify**, written as falsifiable claims ("check X returns 401",
   "run Y and confirm Z"), not as "looks good".
5. Open questions, assumptions made, and anything deliberately left undone.

### 6.2 Reviewing: point by point, in full detail

The reviewer replies to **every** numbered claim in the PR — quoting the claim and stating
agree / disagree / needs evidence, with the evidence. Vague approvals ("LGTM") are not reviews.
Both agents append their exchange to `docs/QA/DISCUSSION-LOG.md` using its entry format, so the
reasoning survives and can be re-read later. Assume the other agent has *not* seen your screen,
your terminal or your reasoning: write what you saw, verbatim where it matters.

### 6.3 Disagreement and escalation

- One exchange of evidence-backed disagreement is mandatory before concluding either way.
- If both agents still disagree, add the `needs-human` label and stop; the human decides.
- Never merge over an unresolved objection. Never re-open a settled decision without new evidence —
  cite the decision (date + where it was recorded) instead.

### 6.4 Enforcement (and its honest limits)

GitHub branch protection is **unavailable on private repos on the free plan** — the API returns
`403 Upgrade to GitHub Pro or make this repository public to enable this feature`. So the rule is
enforced by the combination below. **Read the install note: two ways of installing the hook look
correct and silently do nothing.**

| Mechanism | What it does | Limit |
|---|---|---|
| `scripts/install-git-hooks.sh` → copies `.githooks/*` into `.git/hooks/` | Refuses a push whose destination is `refs/heads/main` | Per clone; must be run once. Verified working (see below) |
| `.githooks/pre-push` + `git config core.hooksPath <ABSOLUTE path>` | Same, driven from the versioned file | The path **must be absolute** — a relative `core.hooksPath` silently resolves to nothing on Git for Windows. Also, the file only exists in checkouts that contain it (i.e. not on `main` before this PR merges) |
| `.github/workflows/main-guard.yml` | Server-side: on every push to `main`, asserts an associated PR exists; fails the run and files a `needs-human` issue otherwise | Detection, not prevention; only active once merged to `main` |
| `.github/workflows/verified-gate.yml` (maintainer decision, 2026-10-19) | On every PR to `main`: fails unless the PR has `state:verified` **and** a comment signed `— Antigravity` or `— Claude` with `Verified-sha: <sha>` matching the current head (§6.5 rule 6) | Binds only once `verified-gate` is a required status check with bypass disabled (`enforce_admins`), because every agent pushes as a repo admin. One shared account: CI cannot prove who wrote the comment |
| This file + PR review | The real control | Relies on both agents honouring it |

**Install (recommended, works regardless of which branch is checked out):**

```bash
scripts/install-git-hooks.sh          # copies .githooks/* into .git/hooks/ and chmod +x
git config --unset core.hooksPath     # make sure no stale/relative hooksPath overrides it
```

**Verified 2026-10-11** (recorded in `docs/QA/DISCUSSION-LOG.md`): with the hook in `.git/hooks/`,
a push to `main` prints `BLOCKED: direct push to main is disabled (AGENTS.md §6 — main is PR-only)`
and exits 1; a branch push exits 0. Two earlier attempts *looked* installed but did nothing — a
relative `core.hooksPath`, and the file being absent from the checked-out ref. Both are documented
above so nobody repeats them.

**Update 2026-10-19:** the repository is public, so branch protection is available and is on for `main`
(PRs required, conversations resolved). The maintainer chose to enforce §6.5 with CI: `verified-gate`
is made a required status check on `main` with "Do not allow bypassing the above settings" turned on.

Maintainer override (deliberate, rare): `OSRA_ALLOW_MAIN_PUSH=1 git push <remote> main`.

### 6.5 Merge rules

**Kimi is the only agent who merges**, for every kind of change: code, tests, CI, docs, `docs/QA/**`.
Claude and Antigravity review and verify but do not merge, not even their own work. Owning `main` means
owning the merge, not earning a push — the rule above still stands.

A PR may merge only when all of the following hold:

1. **The discussion is fully answered** (§6.2): every numbered claim has an agree / disagree /
   needs-evidence reply, and the restatement matches what was actually built.
2. **The §3 gates are green on the branch, run by someone other than the author.** Antigravity runs the
   software rows; Antigravity or the maintainer runs a hardware row. Kimi's own green run is the floor a
   PR starts from, not the evidence for merging it — for a Kimi-authored change it is explicitly not
   enough.
3. **The verification record is cited.** The merge message names the verifier, the `TR-*` row, the sha
   and the numbers, for example
   `Merge #NNN — verified by Antigravity, TR-NN (probe 109/0 · e2e 69/69 at <sha>)`.
   A merge with no such line is, to the next reader, a merge whose evidence cannot be checked.
4. **The verified sha is the merged sha.** If `main` moved after verification, merge `main` into the
   branch (or rebase) and have the gates re-run; the numbers in the merge message belong to the tree that
   lands. This is the stacked-PR rule 6 in `docs/QA/TESTING-STRATEGY.md` §3, applied at the merge.
5. **Cleanup is done and evidenced** (§7): device, database and cache returned to their found state, with
   the command output in the run log.
6. **The `verified-gate` check is green** (maintainer decision, 2026-10-19). The verifier (Antigravity, or
   Claude for a review-only or docs change) posts a signed comment containing a line
   `Verified-sha: <head sha>` (7+ characters), **then** adds `state:verified`; adding the label is what
   re-runs the check. Any push after that (fix, rebase, merge of `main`) changes the head and turns the
   check red until the new head is verified, which is rule 4 made mechanical. Nobody sets `state:verified`
   on their own PR, and the author never writes a `Verified-sha:` line.

**Docs-only changes are no exception**, but the check is proportional: the verifier reads the diff line by
line and confirms that every cited `file:line` says what the text claims. The merge message says who did
this and against which sha, because a citation that no longer resolves is a documentation bug (§8).

**A revert** of a bad merge is verified by running the gates on the reverted tree and posting that output.
It is cheaper than the original verification, not exempt from it, and it carries nothing else in the same
PR.

**When verification cannot happen** — the handset is leased to another lane, a gate needs a host no one
else reaches — leave the PR open, state under its own heading what was *not* verified and why, and let the
human decide. Never merge on the author's assurance, and never relabel an author's run as verification.

**Maintainer override** (deliberate, rare), as in §6: the human may direct a merge these conditions do
not cover. The deviation is then named in the merge message and recorded in
`docs/QA/DISCUSSION-LOG.md` with the reason, so the next reader sees an exception that was decided rather
than a rule that was forgotten.

Merging is not approval of the other agent's competence — it is a claim that the evidence in the PR
justifies the change.

## 7. Device and environment hygiene (standing rule, human-mandated 2026-10-11)

Every test — automated or on hardware — ends with the environment as it was found. Specifically:

- **Physical device:** uninstall the app(s) under test (`adb uninstall <pkg>`), remove port forwards
  (`adb reverse --remove-all`), force-stop anything left, and confirm no package or data directory
  remains (`adb shell pm list packages | grep -i familyshield` → empty). Access is leased (§9); a
  parental `lock`/`pause`/ring left standing is a collision with the next tester, not a handover.
- **Test database:** delete the rows a run created. Keep the seeded demo family
  (`demo@familyshield.dev` / child `Alex` / device `Pixel 7a`) and nothing else:
  `psql -h 127.0.0.1 -U familyshield -d familyshield -v apply=1 -f services/api/scripts/cleanup-test-data.sql`
  (dry run without `-v apply=1`).
- **Cache:** check Redis for keys belonging to deleted entities; anything persistent (TTL `-1`) must be
  removed or explained. Keys that expire on their own need no action.
- **Report it:** say in the run's log/PR what you cleaned, with the verification command output. "I
  cleaned up" without evidence is not cleanup.

Rationale: the phone belongs to the human and carries real notifications/accounts; the database is what
the human and testers look at for demos and decisions. Test residue in either one is misleading.

## 9. The physical test device — one lease at a time (standing rule, 2026-10-17)

There is exactly one physical Android handset: the maintainer's Samsung Galaxy Z Flip4, `adb` serial
**R5CW116Y6GF**, attached to the Windows host. Every agent session on that host reaches the same phone,
so access is serialised by a lease. This is binding even when a run "only takes a minute".

**Why.** On 2026-10-17 a `lock` command was left applied while the agent that sent it went unreachable.
The phone sat behind the parental overlay while the Phase 1 gate (`TR-15`, the ten-bypass probe) needed
the handset. A rule that depends on the previous owner being reachable is not a rule; the lease below
does not.

### 9.1 Who may use it

- **Who may touch it:** the human maintainer; the device warden, for a takeover or a reset; and the
  current leaseholder, for the purpose in the claim. Nobody else, and a free phone is not an invitation —
  the accepted purpose and the held lease are both required.
- The **device warden** owns the rule and arbitrates: accepted purposes, conflicts and break-glass. From
  2026-10-17 that is the programme lead, Kimi Code. The human maintainer outranks the warden at all
  times: when the human wants the phone, the lease is suspended, the current owner stops, clears the
  device state (§9.4) and says so on the board.
- A lease is valid only for an accepted purpose: a `TR-*` row in `docs/QA/TEST-REQUESTS.md` or a work
  order on that board. "Looking at something" is not a purpose; if there is no row, ask for one. A claim
  for anything else is not a lease and the warden may break it.
- The warden may hold a lease. The rule is the same for the warden, including the end time and the
  release record.

### 9.2 The lease

- The lease is `scripts/hardware/phone-claim.ps1`. It records permission, not hygiene, and never calls
  `adb`. Claim before the first command:
  `.\scripts\hardware\phone-claim.ps1 -Action Claim -Owner "<agent>" -Purpose "<TR-id: what you are running>"`.
  Exit 0 means the phone is yours; exit 1 means someone else holds it (`-Action Status` shows the holder
  and the time left; `-Action Wait -WaitMinutes N` queues for it).
- Announce the same claim on the board (`docs/QA/TEST-REQUESTS.md`, Messages):
  `DEVICE R5CW116Y6GF — <agent> — TR-15 — claimed until <HH:MM> UTC`. The store is the lock; the board
  line is how a human and a remote agent see it. If the two disagree, `-Action Status` wins.
- Default 60 minutes, hard ceiling 4 hours (`-Minutes` is rejected outside 5..240). Renew with
  `-Action Heartbeat -Owner "<agent>"` before the end time — before a build and between long probe
  sections; nothing renews it in the background.
- At the end time the lease **expires automatically** and the next claimant takes it. This is
  deliberate: an unreachable agent must not block the programme. Expiry does not clean the phone — the
  next holder runs the pre-flight in `docs/TESTING.md` §5.0.
- One lease, one agent. Do not sub-let, do not schedule another agent's step inside your window, and do
  not hold the lease while you build. Build and analysis need no device; claim when the first `adb` or
  command step is ready to run.
- Honest limit: the store is a local file on this Windows host (the path is printed by `-Action
  Status`), so it binds agents that share the user account; a second host needs `-Store` at a share
  both sides can write. A remote agent must honour the board line; the script cannot reach a process
  that never reads it.

### 9.3 Device state is part of the lease

- **A lock is a test action, never a reservation.** Do not use `lock` to hold the phone while you are
  away, and do not end a lease with a restriction still applied, even a deliberate one.
- Any run that applies a restriction clears it before the release — `unlock`, plus `stop_ring` /
  `resume_internet` where applicable — and verifies it (`docs/TESTING.md` §5.0).
- Check for **queued** restrictions at handover, not just visible ones: the command queue is durable and
  the agent polls every 60 s, so a `lock` sent near the end of a lease can land after the next owner has
  started. `GET /v1/devices/:id/commands/history` must show no `pending` or `delivered` restriction from
  the previous owner before you begin.
- The **keyguard** is the human's lock screen, not ours: agents must not guess, reset or change the
  phone's PIN/pattern, and must not change developer options, accounts or OS updates. The parental
  overlay is not the keyguard and is cleared with `unlock`.
- Toggles changed for a run (accessibility service, overlay app-op, Private DNS, alarm volume) are
  restored to their previous values, not merely "left working".

### 9.4 Release and takeover

Release is the last step of every run, together with §7: clear restrictions, verify no `LockActivity`
overlay remains, then uninstall / `adb reverse --remove-all` as §7 says, then release the lease:

```powershell
.\scripts\hardware\phone-claim.ps1 -Action Release -Owner "<agent>" -LeftState Clean -Note "app uninstalled, reverse removed"
```

`-LeftState` is mandatory and must be honest: `Clean`, `Locked` (the OSRA overlay is still up) or
`Unknown` (not checked). `Locked` is a warning to the next holder, not a handover. Quote the claim and
the release (from `-Action Status` or the journal) in the run log or PR — they are the evidence that the
device was yours.

Takeover:

1. An **expired** claim needs no ceremony: `-Action Claim` takes it and journals `EXPIRE`. One contact
   attempt on the board is courtesy, not a precondition.
2. A **live** claim held by an unreachable agent needs the warden's break-glass:
   `-Action Break -Owner "<warden>" -Purpose "recover the handset" -Reason "<why>" -Force`. The reason
   (10 characters or more) goes in the journal. The break acquires the claim for the warden — release it
   after the reset if you are not running the test.
3. Before the first `adb` command, apply the reset in `docs/TESTING.md` §5.0: `unlock` through the API
   (safe-direction, no consent needed), allow up to 90 s (the 60 s poll plus delivery), then verify the
   overlay is gone.
4. If the **keyguard** is showing, stop: only the human unlocks the phone. A takeover of a
   keyguard-locked handset waits for the human; it is not a reason to try a PIN.
5. Record the state you found (`dumpsys` output) in the run log. A takeover is evidence about a process
   gap, not a verdict on a person.

### 9.5 What a collision costs

A run without a held lease — or one that collides with another agent's lease — is **not evidence**: its
results are void in the PR/test report and the warden may require a repeat. A reviewer may ask for the
lease line the same way it asks for a gate output.
## 10. Work state — how an agent says "do not touch this yet"

The failure this prevents: a checker picks up a branch that is mid-build, tests a half-finished tree, and
reports a defect that was simply "not done yet" — or interrupts a hardware run and then cannot explain
the strange number it got. Both happened here on 2026-10-17, and both cost more than the labels do.

One label, one meaning, set by the **author** and read from a single API call (`GET /pulls` carries
`draft` and `labels`, so a whole pass costs one request):

| Label | Meaning | What everyone else must do |
|---|---|---|
| `state:wip` | In progress. The default for a draft PR, labelled or not | Nothing. No test, no review, and no comment asking for work |
| `state:ready-for-verification` | Finished: tests written, the author's own gates run | The testing lane may start. Set `state:verifying` when you do |
| `state:verifying` | A tester holds it | Author: no force-push, no rebase. Others: stay off it |
| `state:verified` | Gates re-run by someone other than the author, numbers and a signed `Verified-sha:` line on the PR (§6.5 rule 6) | The development lead merges on it once `verified-gate` is green |
| `state:changes-requested` | Verification failed, or the restatement was wrong | Author fixes and returns it to `ready-for-verification` |
| `state:needs-arch` | Waiting on an architecture decision (KCL lead) | Everyone else waits; the decision is recorded in an ADR or the log |
| `state:blocked` | Needs something outside the repo — a key, a phone, a merge, an entitlement | Say what, and who has it, in the PR and on the board |

Rules:

1. **A draft PR is WIP** whether it carries a label or not. Do not test a draft.
2. **A head commit younger than 10 minutes means "in flux"** — assume WIP even if the label says ready.
   This is the cheap guard against testing a tree that is still being written.
3. **The author sets the state; the tester only moves it forward** (`ready` → `verifying` →
   `verified`/`changes-requested`). Nobody relabels someone else's work back to `ready` to claim it.
4. **Silence is not readiness.** No label means WIP, not "please test". If it matters, ask on the PR.
5. **The label does not grant the phone.** Hardware needs the lease (§9), which is a separate control
   with its own expiry, because a label cannot tell you the handset is in someone's hands.
6. **One state per PR.** If it is both blocked and verified, `state:blocked` wins: the label answers
   "can I act now?", and the answer is no.

## 11. Identity — say who you are, because the account cannot

**All three agents post as the same GitHub account** (`handfullofluck-lab`). Every comment in this repo
therefore looks as though one person wrote it, `@`-mentions notify nobody, and a reviewer cannot tell the
verifier from the author by looking at the login. On 2026-10-17 the maintainer's fair criticism was "I
did not see any recent comms among you guys" — the messages existed, and the medium hid them.

So identity is part of the message:

1. **Comments and TR messages are signed.** Board and `docs/QA/TEST-REQUESTS.md` lines end
   `— <Agent> (<role>) → <addressee>: …`; PR comments open with `**<Agent> (<role>) →**`. The role word
   matters as much as the name, because roles changed on 2026-10-17 and a reader needs to know which
   hat was on.
2. **Commits carry a trailer** — `Co-Authored-By: Kimi Code <dev-lead>`, `… Antigravity <testing>`,
   `… KCL lead <architecture>` — so `git log` shows the pair, not a single author.
3. **A silence is not an absence.** If an agent has not replied, the message says when it was sent and
   what the default is, so the next reader can act without waiting. Never interpret no-reply as agreement.
4. **Do not quote another agent's words as your own.** When summarising someone else's result, name
   them, and cite the sha/`TR-*`/comment it came from.
5. **The fast channel is a host-level mailbox, outside every repo:** `C:\KARIM\collab\` (its `README.md`
   and `collab.ps1`). One file per message, one ask per message, acknowledged by moving the file to
   `inbox/<agent>/read/`, and every request carries a **default if silent**. It is a convenience, not the
   record: a decision that exists only in the mailbox is not finished.
6. **The durable channel is the file, not a direct message.** With one account there is no private inbox
   between agents: `docs/QA/TEST-REQUESTS.md` is the request board, the `TR-*` row is the unit of work,
   and this log is the record. Anything that only exists in a chat window is lost when the session ends.

## 12. Roadmap alignment, documentation and findings (maintainer, 2026-10-17)

The maintainer re-cut the roles on 2026-10-17, in his words: *"architecture is your [Claude's] decision
and that is clear to the team, you help with constructive testing with detailed feedback on how to fix
the bug or issue. KIMI do the developments, antigravity support with testing solely and reporting
findings."* §1 carries the table; this section carries the three rules he attached to it.

1. **Every PR names its roadmap item and moves its row.** The PR title or first line cites the
   `docs/ROADMAP.md` item it delivers (`plan 2.6`, `plan 1.9`), and the same PR updates that row's status
   and evidence. Work that matches no roadmap item gets a row first, agreed on the board
   (`docs/QA/TEST-REQUESTS.md`), before the code. A row's *Acceptance* line is the contract: scope beyond
   it is a new row, not a bigger PR.
2. **Every change is documented in the same PR** (§8, unchanged and enforced): `CHANGELOG.md`, an ADR for an
   architectural decision, `docs/TESTING.md` for a procedure or gate. A reviewer returns a PR whose docs are
   missing, the same way as a red gate.
3. **A finding carries its fix.** Claude's review findings and test failures state: what was run and what it
   printed (verbatim), the cause with `file:line`, the change to make, and the test that must fail before
   that change and pass after it. Antigravity reports findings with the same evidence (run, output,
   expected/actual); the fix guidance is Claude's job, the fix is Kimi's.
4. **Claude checks each PR against its roadmap row** before a TR row is marked verified, and says on the
   board when a PR drifts from its row (unmet acceptance, or scope the row does not hold).
