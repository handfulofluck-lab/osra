# Verification ledger — the batch after `f2437a9` (the 2026-10-19 ledger)

**Written 2026-10-19 00:20 +0400 (2026-10-18 20:20Z) by Kimi Code (development lead).** This is the
successor to [`VERIFICATION-LEDGER-2026-10-18.md`](VERIFICATION-LEDGER-2026-10-18.md), which froze at
**31 merges** ending `f2437a9` (2026-10-18 16:19Z). This file covers **every pull request merged after
that sha, up to `origin/main` = `4e56410`**: **13 merges**, `162a3e4` (16:55:43Z) → `4e56410`
(20:00:18Z), all merge commits, no direct push.

Nothing below is a re-run I performed, except the `file:line` re-reads of the code and docs that the
"paid" verdicts in §4 rest on (each names the line it read; §7 lists the files), and
`node scripts/check-docs-links.mjs`, whose raw output is in this change's pull request. It is a ledger of
**what is on record**, not a new verification.

> **Refreshed later the same day — 2026-10-19 10:10 +0400 (06:10Z).** The day did not stop at `4e56410`.
> **Eighteen more merges** landed between that sha and `origin/main = 025be5b` (05:43:16Z), and §8–§15
> below record them the same way: one row per PR, the numbers **quoted** from the merge message, no
> promotion, and a new section (§11) on what is now **blocked** rather than pending on hardware. §1–§7
> are unchanged except for the three pointer sentences marked *(second half)* — a past state is
> superseded here, never deleted (`AGENTS.md` §8).

> **Refreshed again — 2026-10-19 18:20 +0400 (14:20Z).** **Eleven more merges** landed between
> `025be5b` and `origin/main = 01c98a9` (10:40:18Z), and §16–§22 below record them: one row per PR with
> the numbers **quoted**, a section on the new **process gate** (`verified-gate` — what it enforces now,
> why it is not a required check, and what binding it would cost), the reviews that arrived in this
> window, and an updated risk-ordered re-run list in which every earlier tamper PASS is now explicitly
> **not evidence** (#200). §1–§15 are unchanged. **0 tester-verified, 11 author-run**; the file now holds
> **42 merges** (`162a3e4` → `01c98a9`).

## 1. The boundary, because the filename and the clock disagree

The file is named for the maintainer's local day (**UTC+0400**, the clock the day is named by), and the
range is defined by **sha**, not by a calendar boundary:

| Reading | Range | Merges |
|---|---|---|
| local (+0400) | 2026-10-18 20:55 → **2026-10-19 00:00:18** | 13 — but only the last (`4e56410`) falls on the local 10-19 day |
| UTC | 2026-10-18 **16:55:43Z → 20:00:18Z** | 13 |
| `git log --first-parent --merges --since=2026-10-19T00:00:00+0400` | — | **1** |
| `git log --first-parent --merges --since=2026-10-18T00:00:00Z --until=2026-10-19T00:00:00Z 603a33d^..4e56410` | the whole UTC day | **44** = yesterday's 31 + these 13 |

So the honest description is: **this is a continuation ledger, keyed by `f2437a9`, not a day's batch.**
Twelve of the thirteen merges are still 2026-10-18 in both clocks; the day only turns over on the merge
that closes this range. Anyone who needs "the 2026-10-18 UTC day" reads both files (44 merges); anyone
who needs "everything after the last ledger" reads this one. Yesterday's file recorded a boundary case
(`f25ed54` with a `+0400` date of 10-18 but a UTC merge time of 10-17) — this is the same trap one layer
up, and it is written down here rather than left for the next reader to rediscover.

The range contains **20 merge commits**, of which **7 are `merge: main into <branch>` syncs inside a PR
branch** (`91cbb3a`, `c63b938`, `cce4d01`, `ebf71cc`, `ea41c4d`, `c94aa15`, `731a0ae`). They are not PR
merges and have no row. `--first-parent` returns exactly 13.

## 2. How to read a row

The definitions are yesterday's, unchanged, and repeated here so this file can be read on its own:

| Status | Means | What it does **not** mean |
|---|---|---|
| **tester-verified** | An agent other than the author produced a record **against the tree that merged**: it re-ran the gates, or for a docs-only change it read the diff line by line and confirmed every cited `file:line` | That every claim in the PR was tested — only the ones the record names |
| **author-run** | The only numbers on record are the author's (or the lead's, acting as author/merger). They may be complete, honest and fail-before-backed; they are still one party's word | That nobody else *could* run it — only that nobody else did |
| **unverified** | No run is on record, or the run happened against a different tree than the one that landed | That the change is wrong — it means the evidence does not exist yet |

A number written `probe 130/0` is the run's own summary line (`130 passed · 0 failed`).
`integrity 103→109` is `node scripts/check-probe-integrity.mjs --base origin/main` (check counts before
→ after, and how many assertions were added or removed). "head" is the PR head **at merge**, i.e. the
second parent of the merge commit — the sha the numbers should belong to.

## 3. The 13 merges

Sorted by merge time (UTC). Quotations are verbatim from the merge message (`git log -1 --format=%B
<sha>`) or the PR body/comment, as marked.

| PR | Title | Merged as (time) | Head | Who ran what · exact numbers claimed | Status |
|---|---|---|---|---|---|
| [#143](https://github.com/handfulofluck-lab/osra/pull/143) | docs(qa): verification ledger for the 2026-10-18 merges | `162a3e4` 16:55:43Z | `ff9c061` | **Kimi (author, docs).** links *"0 broken link(s) out of 127 checked in 66 Markdown file(s)"*, `EXIT=0`. **Non-author record:** Claude's diff read at **16:46:16Z**, on this head, closed *"With those three changes, I approve the docs from the architecture side"* — and **none of the three is in the merged tree** (§4.3, item 1) | author-run — the one non-author read ended **conditional and unfulfilled** at merge; the conditions landed as record amendments on 2026-10-19 (**§4.4**) |
| [#144](https://github.com/handfulofluck-lab/osra/pull/144) | docs(adr): 0023 — MFA recovery via one-time codes (proposal) | `c241cab` 16:55:50Z | `1d5a149` | **Kimi (author, docs).** vitest **32 files / 349 passed** under `--pool=forks` only; the **default-pool run failed in that worktree** (*"4 failed \| 11 passed (15)"* in `auth.test.ts`, 20 s argon2 timeouts) and the PR says it does **not** claim the default gate green; `git diff --check` clean; live proof of the takeover, `takeover: true`; cleanup `OK: 1 family` + 3 Redis keys removed | author-run — **with a disclosed deviation on the standard §3 command** |
| [#145](https://github.com/handfulofluck-lab/osra/pull/145) | feat(parent-app): design tokens, light/dark themes, Appearance setting (3.8) | `2e6b5aa` 17:11:12Z | `91cbb3a` | **Kimi (author).** merge message: *"Evidence at 91cbb3a (CI 7/7 after merging main; I re-ran on the merged tree): flutter test 134 passed (126 baseline + 8 new), flutter analyze clean"* | author-run — the evidence sha **is** the merged head |
| [#147](https://github.com/handfulofluck-lab/osra/pull/147) | fix(api): password-reset tokens are not bearer credentials (#146) | `f099aa9` 17:21:00Z | `c63b938` | **Kimi (author).** PR body at `1b7da49` (the head **before** the final `merge: main`): vitest **352/352**, probe **124 passed · 0 failed** incl. `G19` on a spare `:3100`, e2e *"68 passed, 0 failed"*, integrity `102→103, 0 removed`, live reset matrix `3/3`. Merge message: *"I re-ran vitest 352 passed and the integrity check on the merged tree"* at `c63b938` | author-run — **live half at the pre-merge head; unit + integrity at the merged head** |
| [#148](https://github.com/handfulofluck-lab/osra/pull/148) | docs(qa): the 2026-10-18 discussion-log entry | `8cdc42e` 17:39:06Z | `8de7405` | **Kimi (author, docs).** links *"0 broken link(s) out of 129 checked in 67 Markdown file(s)"*, `exit=0`; append-only proven by numstat **324/0** | author-run |
| [#149](https://github.com/handfulofluck-lab/osra/pull/149) | fix(api): a failed digest send releases its claim; `DIGEST_HOUR` is local everywhere (#93 F1/F2/F3) | `0cc9cad` 17:39:17Z | `66e072d` | **Kimi (author).** vitest **358 passed** (352 on `main`); fail-before on `origin/main`'s three source files **5 failed \| 25 passed (30)**; integrity `103→103, 0 added`; real-Postgres scratch run: *"permanent": attempted 1 sent 0* → one terminal row, *"nextTick": attempted 0*, *"nextDay": attempted 1 sent 1*; scratch DB dropped. Merge message adds migration `0016` applied before the probe run. **probe/e2e not run** | author-run |
| [#150](https://github.com/handfulofluck-lab/osra/pull/150) | test(probe): gate the three fixes #124 merged (#121–#123) | `4adc601` 17:54:48Z | `cce4d01` | **Kimi (author).** integrity **103→109, 6 added, 0 removed**; probe **130 passed · 0 failed** twice (17:26Z, 17:27Z) with `G20`–`G23`, `N6d`, `N6e`; a third attempt inside the same minute aborted with **exit 2** (`RATE LIMIT`); e2e **69 passed, 0 failed** with `DATABASE_URL` after a 60 s gap; vitest 352/352. Probe ran **against the shared `:3000`, which runs `main@f099aa9`** — the branch changed only the probe | author-run |
| [#152](https://github.com/handfulofluck-lab/osra/pull/152) | docs: land the two 2026-10-18 review promises (merge-ref trap, row-3 proposal) | `86a711e` 18:21:51Z | `b52a7e4` | **Kimi (author, docs).** links *"0 broken link(s) out of 131 checked in 68 Markdown file(s)"*, `exit=0`; merge message: *"links 0/131; CI 7/7"* | author-run |
| [#154](https://github.com/handfulofluck-lab/osra/pull/154) | docs(qa): S1 and S1b measured PASS on `main@4adc601` (TR-21) | `b530618` 18:37:33Z | `e822865` | **Kimi (author) + hardware, on the Flip4 (`R5CW116Y6GF`).** *"a real lockNow() raised the keyguard … the Samsung emergency dialer held the front at 2.4/6.3/11.3 s on Full and 2.3/6.4/11.4 s on a clean Play install"*; links 0/131. **Non-author record:** Claude *"read and accepted from the architecture side"* at **18:46:39Z** — nine minutes after the merge — and said so itself: *"this is an author run. An Antigravity re-run on the same sha is still what makes it verified"* | author-run (hardware) |
| [#153](https://github.com/handfulofluck-lab/osra/pull/153) | feat(3.2): parent pairing code as a scannable QR | `69d1575` 18:37:40Z | `8255835` | **Kimi (author).** `flutter analyze` *"No issues found! (ran in 3.3s)"*; `flutter test` *"+146: All tests passed!"* (134 before, 12 new). Merge message: *"Evidence at 8255835 (CI 7/7 after merging main)"*. **Non-author ask:** Kimi asked Antigravity to re-run at **18:16:33Z** (PR comment); no reply on record before the 18:37:40Z merge | author-run — **verification requested, unanswered at merge** |
| [#156](https://github.com/handfulofluck-lab/osra/pull/156) | fix(api): revoke parent sessions by counter, not the second (#117) | `0d0418c` 19:40:02Z | `923a695` | **Kimi (author).** vitest **361 passed**; fail-before *"3 failed \| 9 skipped (12)"*; probe **130 passed · 0 failed** on a spare `:3017` with `F8`/`N2` asserting the same-second property; e2e **69 passed, 0 failed**; integrity `109→109, 0 removed`; links 0/132; cleanup `1 family / 1 child (Demo Family / Alex)`, 3 orphan keys reaped | author-run — evidence sha **is** the merged head, on a branch-built server |
| [#157](https://github.com/handfulofluck-lab/osra/pull/157) | test(android): assert the merged manifest, not the source (#101 F2) | `747c757` 19:50:56Z | `731a0ae` | **Kimi (author).** `./gradlew testPlayDebugUnitTest testFullDebugUnitTest assemblePlayDebug --no-daemon` *"BUILD SUCCESSFUL in 1m 59s"*; **41 suites / 264 tests / 0 failures** per flavour; `check-merged-manifest-gate` — *"2 result set(s) checked, all assertions ran and passed"*, `exit=0`, and three doctored-input cases each `exit=1`; fail-before: an AAR declaring only `READ_SMS` turned **2** assertions red while `FlavorManifestTest` stayed **green** in the same build; links 0/131; workflows `0 error(s), 0 warning(s)`. Merge message: *"264 tests per flavour, 0 failures; check-merged-manifest-gate reports 2 result sets, all assertions ran"* at `731a0ae` | author-run |
| [#155](https://github.com/handfulofluck-lab/osra/pull/155) | fix(android): no location FGS without the background grant; `locate_now` reports why (#132) | `4e56410` 20:00:18Z | `c94aa15` | **Kimi (author).** fail-before *"16 tests completed, 6 failed"*, `BUILD FAILED in 9m 14s`; after, per flavour `suites=42 tests=267 failures=0 errors=0 skipped=0`, both APKs assembled; merge message: *"CI 7/7 after merging main twice … the 16 new tests fail against the pre-fix tree (6 failures)"*. **Hardware path not run** (revoke background location while the agent polls) and the PR says so | author-run |

**Totals: 13 merges — 0 tester-verified, 13 author-run, 0 with no run at all.** Of the 13, **8 changed
code or tests** (#145, #147, #149, #150, #153, #155, #156, #157) and **5 are docs/QA-only** (#143, #144,
#148, #152, #154). Two non-author records exist in the whole batch (#143's conditional diff read at the
merged head; #154's acceptance of the hardware evidence, nine minutes late); **neither is a pass, and
neither is upgraded here.** *(second half)* The 18 merges after `4e56410` are in §9: **0
tester-verified, 18 author-run, 0 with no run**, and for the first time in this record a non-author
review arrived **before** a merge and named changes — which the merge then shipped without (§12).

Named claims inside these PRs that **no one has run**:

- **#155** — the hardware failure path: background location revoked while the agent polls, and the
  `failed` ack with `reason: background_location_missing` reaching `/commands/history` on a device.
  JVM-proven only.
- **#153** — the QR scanned by the child app (the scanner does not exist yet) and the 5-minute
  non-engineer first-run test; the payload format is unit-tested, the acceptance line is not.
- **#157** — the **release** merged manifests; only `debug` is asserted, so a `releaseImplementation`
  dependency or `src/release/AndroidManifest.xml` declaration would still escape.
- **#145** — dark mode by eye, Arabic/RTL (3.1), and every screen not migrated.
- **#147** — `G19` has exactly one run, the author's, at `1b7da49` rather than the merged head.

## 4. The debts, closed or not

### 4.1 Yesterday's seven, one verdict each

| # | The debt as yesterday's ledger recorded it | Verdict | Evidence (read at `4e56410`, or the PR that decided it) |
|---|---|---|---|
| 1 | **#93 merged over a changes-requested review; F1/F2/F3 still open on `main`** | **paid** | [#149](https://github.com/handfulofluck-lab/osra/pull/149) `0cc9cad`. Read at `4e56410`: the `catch` calls `releaseClaim()` (`services/api/src/jobs/digestScheduler.ts:163-165`); `retryable === false` → `retireClaim()`, else release (`:148-158`); `.env.example:19-22` is `DIGEST_HOUR=18` with the local-hour rule and `DIGEST_HOUR_UTC` as the deprecated alias; `docs/TESTING.md:98` names it as the family's local hour (**was `:66` when #149 merged — #152's rewrite of that page moved it**, which is why the citation was re-read rather than copied). **One loose end:** issue [#99](https://github.com/handfulofluck-lab/osra/issues/99) is still **open** for a defect that is fixed — closure bookkeeping, same class as #134/#137 which #150 closed |
| 2 | **#139's live gates ran against the pre-merge tree; the branch's own auth changes were never exercised live** | **changed** — the blanket gap is closed, the targeted check is not | #139 has been live since: #147's probe `124/0` at `:3100`, #150's probe `130/0` against `:3000` on `main@f099aa9` (which contains #139), #156's probe `130/0` at `:3017`. What is still missing is the *targeted* negative: a co-parent token on a **sibling family** returning `403`, from a second party |
| 3 | **#124 added no probe check and ran no live gate** | **paid** | [#150](https://github.com/handfulofluck-lab/osra/pull/150) added `G20`–`G23`, `N6d`, `N6e`. Present at `4e56410`: `services/api/scripts/qa-probe.mjs:569,571,582,585` (`G20`–`G23`) and `:930,936` (`N6d`,`N6e`); integrity `103→109, 0 removed` |
| 4 | **#84's sign-off is at `29f78d8`, the branch merged at `1224768`** | **still open** | No non-author read of the merged head is on record, then or since. #152 rewrote `docs/TESTING.md` around it but did not re-read `AGENTS.md` §1's cadence text, which is what #84 changed |
| 5 | **#125's verification postdates its merge by 23 s, so no merge message cites it** | **changed — the habit got worse, not better** | In this batch **no merge message names a verifier, a `TR-*` row or a verification sha**. #143 merged **9 min after** a review whose three conditions never landed; #154's acceptance arrived **9 min after** its merge; #153 was merged **21 min after** a verification request that was never answered. The rule §6.5(3) asks for is possible to follow — it was simply not followed |
| 6 | **The durable log is empty for 2026-10-18** | **paid** | [#148](https://github.com/handfulofluck-lab/osra/pull/148) appended one entry (`docs/QA/DISCUSSION-LOG.md:2050`, 324 added lines, 0 deleted). It transcribes #93/#96/#101/#125 and the security batch, names the two real defects and ends risk-ordered |
| 7 | **The UI-only PRs rest on widget tests** | **still open, and grew by two** | #145 (`flutter test` 134) and #153 (146) join #107/#109/#116/#142 in exactly the same condition: a widget suite, no live-stack walk-through, no device. Neither PR claims more than that; the gap is that nothing else exists |

### 4.2 The carry-overs this batch was supposed to pay

| Item | Verdict | Where it stands |
|---|---|---|
| **#101 F2 — every manifest gate read the source, not the merged artifact** | **paid** | [#157](https://github.com/handfulofluck-lab/osra/pull/157) `747c757`: `PlayMergedManifestTest`/`FullMergedManifestTest` parse `merged_manifests/<flavor>Debug/**`, an allow **and** deny list, the test tasks depend on `process<Flavor>DebugManifest`, and `node scripts/check-merged-manifest-gate.mjs` (CI step) fails on a missing result set, a skip or a renamed assertion. The fail-before is the strongest evidence in the batch: a 498-byte AAR declaring `READ_SMS` turned two assertions red while the old source test stayed green |
| **#96's merge-ref trap ("No checks reported" = conflicting, not pending)** | **paid** | [#152](https://github.com/handfulofluck-lab/osra/pull/152): `docs/TESTING.md:439`, with the symptom, the cause (`refs/pull/<n>/merge` is never created for a `CONFLICTING` PR), the fix and the date |
| **#127's row-3 amendment** | **changed — accepted, but the record still says "proposal"** | [#152](https://github.com/handfulofluck-lab/osra/pull/152) wrote it as **PROPOSED** at `docs/QA/TESTING-STRATEGY.md:62-121`. Claude **accepted** it in a comment on [#154](https://github.com/handfulofluck-lab/osra/pull/154) at 18:46:39Z — row 3's gate becomes "the parent receives `device_silent` within the silence window after `am force-stop`". Read at `4e56410`: `docs/QA/TESTING-STRATEGY.md:64` still reads **"Status: PROPOSED — not accepted."** The decision exists in a PR comment, which is the medium §11.6 says loses it |
| **#146's MFA takeover (a reset token was a bearer credential)** | **paid** | Found while writing ADR-0023 ([#144](https://github.com/handfulofluck-lab/osra/pull/144)), filed as #146, fixed by [#147](https://github.com/handfulofluck-lab/osra/pull/147): `isBearerSession` required in `requireJwt`/`requireAuth`/`requireParent`/`requireFamily`, `G19` added. **Author-run only; a second party has never reproduced `G19`** |
| **The app PIN published in a repo doc** (Claude's #143 review item 2; issue [#151](https://github.com/handfulofluck-lab/osra/issues/151)) | **still open** | redacted on 2026-10-19 by PR #164 (the literal is gone from `docs/` and `scripts/`; the probe now requires `-Pin`). Rotation of the physical test PIN is the maintainer's call and issue #151 tracks it |

### 4.3 New debts this batch creates

1. **#143 merged with all three review conditions unfulfilled** — and one of them is a secret in a doc
   (`docs/QA/TEST-REQUESTS.md:20`), now tracked as #151. The other two: the ledger's #131 row still lacks
   `known incomplete: #132` (`grep -n "#132" docs/QA/VERIFICATION-LEDGER-2026-10-18.md` → no output),
   and re-run item 8 still omits the while-in-use-only case. The code half of the first one is moot —
   #155 closed the #132 hole — but the record still reads as if it were clean.
   **Amended 2026-10-19: all three are now met — see §4.4.** The `TEST-REQUESTS.md:20` citation above
   no longer resolves either: later board inserts moved that message to `:22` (§8: a citation that no
   longer resolves is a documentation bug).
2. **A decision that exists only as a comment.** Claude's row-3 acceptance (§4.2) is the batch's only
   architecture acceptance and it is not in the file it governs. One docs line, and it is not mine to
   write as accepted without the citation; it is in the re-run list (§5, item 10).
3. **#153 merged while a verification request was open.** The ask went to Antigravity at 18:16:33Z; the
   merge was 18:37:40Z. Either the request was not a precondition (then do not send it) or it was (then
   the merge was early). §6.5 has no reading in which both are fine.
4. **#144's standard gate was never green where it was written.** The default `vitest` pool timed out on
   argon2 in a fresh worktree and the author switched to `--pool=forks` and disclosed it. That is the
   right way to handle it, and it is a **reproducible environment trap** — a fresh worktree, not a
   primary clone — that `docs/TESTING.md` §6 does not yet carry. Every later "fresh worktree" run pays
   for it again.
5. **#150's checks have never been shown to fail.** The PR names the three mutations that should turn
   `G20`/`G22`/`N6e` red and says the experiment was **not** run. A check nobody has seen fail is a
   check that may be vacuous — the same criticism #157's fail-before answers for its own gate.

### 4.4 Claude's three conditions on #143 — where each stands after 2026-10-19

Claude's diff read of [#143](https://github.com/handfulofluck-lab/osra/pull/143) at 16:46:16Z
(§3, the #143 row) set three conditions before a merge that then happened without them. This section is
the **dated disposition**, not a rewrite of §4.3: two of the three were record bugs, the code half was
fixed the same evening, and none of it upgrades a run.

| # | The condition, as Claude wrote it | Met? | By what |
|---|---|---|---|
| **1a** | the #131 row must read "author-run, known incomplete: #132" | **met** | [`VERIFICATION-LEDGER-2026-10-18.md`](VERIFICATION-LEDGER-2026-10-18.md) §2's #131 row now carries the words, with a dated note that #132 is fixed by [#155](https://github.com/handfulofluck-lab/osra/pull/155) (`4e56410`, 20:00:18Z; issue #132 closed 20:00:20Z). The code it describes, read at `1733d83`: `BootStartPolicy.kt:36`, `AccessibilityMonitorService.kt:144-166` and `CommandDispatcher.kt:247` all consult `LocationStartPolicy.kt:41-49` |
| **1b** | #111 fixed the probe only — add the #117 debt | **met** | that ledger's §3 **item 8**, which names the fix: [#156](https://github.com/handfulofluck-lab/osra/pull/156) (`0d0418c`, 19:40:02Z; issue #117 closed 19:40:04Z). Read at `1733d83`: `services/api/src/lib/sessions.ts:114` (`incrby` the counter), `:128-129` (refuse a lower `sv`), `:133-134` (inclusive legacy fallback — the revocation second is dead) |
| **2** | the app PIN must come out of `docs/QA/TEST-REQUESTS.md` (and TR-21) | **met** | [#164](https://github.com/handfulofluck-lab/osra/pull/164) (`e202c9e`, 2026-10-18 21:47:25Z) removed the literal from `docs/` and `scripts/` and made the hardware probe require `-Pin` with no default (`docs/TESTING.md:356-360`). The 2026-10-18 13:05Z message now reads "the app PIN (held outside this repo)" at `TEST-REQUESTS.md:22`; `grep -rnE 'app PIN [0-9]{4}' docs scripts` returns nothing. #164 used prose instead of Claude's suggested `<app-PIN>` placeholder — the condition's point, no credential in the record, is met. The **rotation** half is not one of the three and is still open: issue [#151](https://github.com/handfulofluck-lab/osra/issues/151) |
| **3** | re-run item 8 (#131) must add the while-in-use-only case | **met** | both re-run lists carry it with the commands: the 2026-10-18 ledger's §4 item 8, and **Block B item 5** below |

**What this section does not claim.** None of the three fixes is tester-verified: #155 and #156 are
`author-run` (the #155 hardware path and the #156 same-second live assertion have only my run), and #164
is a docs change. The conditions were about the **record** being honest, not about promoting a run — the
rows in §3 stay as they are. A second party still owes Block B item 5 (the while-in-use row) and Block A
item 1 (`F8`/`N2` with no sleep).

## 5. What a verifier should re-run first — in risk order

Ordered by the cost of being wrong. The first block is the API authorization and session-state work, the
second the Android manifest and location work, the third the remaining API correctness and the gates'
own integrity, the fourth UI, and docs last. **One live gate at a time, ≥ 60 s apart** — the shared API
rate-limits at 200 req/min and the later gate aborts with exit 2 (that is the #114/#129 contract, not a
failure). *(second half)* This list covers the 13 merges in §3 only. The 18 later merges — the MFA
recovery surface, the refresh/counter binding, the `testOnly` manifest gate, the block-decision input and
the QR scanner — have their own risk-ordered list in **§13**, which reuses these blocks and adds to them;
nothing below is withdrawn.

### Block A — API authorization and session state

1. **#156 — session revocation by counter** (`0d0418c`). Highest risk: it changes what "this token is
   alive" means for **every** parent token, and it ships a migration-shaped compatibility branch (tokens
   with no `sv` use the legacy epoch **inclusively**). First the unit suite on the merged tree, then a
   branch-built server (§6.3) and `F8`/`N2` with **no sleep** before `logout-all`: the same-second token
   must be `401`. Ask the question the PR itself asks: is the rolling-deploy window acceptable?
2. **#147 — purpose tokens / the MFA takeover** (`f099aa9`). The batch's most serious finding, and its
   `G19` has only the author's run, at the pre-merge head. Re-mint `{sub:<parent>,
   purpose:"password_reset"}` **after** the reset moved the epoch: `/mfa/enroll` and `/logout-all` →
   `401 {"error":"unauthorized"}`; a session token → `200`. Then the four-row reset matrix (no-MFA
   resets; MFA keeps its TOTP; attacker TOTP refused; reset token refused on enroll).
3. **#139's residual** (`9846456`, from yesterday's list) — the one targeted live check nobody has made:
   a co-parent token from family A on family B's child → `403`, not `404` and not `200`. Run it on the
   same branch-built server as item 1; it costs nothing once the server is up.

### Block B — Android manifest and location

4. **#157 — the merged-manifest gate** (`747c757`). Verify it can **fail**: `node
   scripts/check-merged-manifest-gate.mjs` must exit 1 on a doctored XML, and the allow list must match
   ADR-0021's 15 reviewed permissions at `4e56410`. Decide the release-variant gap: acceptable as stated,
   or a Gradle `Copy` from `SingleArtifact.MERGED_MANIFEST` is needed before the next Play upload.
5. **#155 — no location FGS without the background grant** (`4e56410`). Both flavours on a clean build,
   then the one row nobody ran: revoke background location while the agent polls and confirm the
   `locate_now` **failed ack with `reason: background_location_missing`** appears in
   `/v1/devices/:id/commands/history` (needs the lease; §6.7). **Amended 2026-10-19 (Claude's
   condition 3, which named item 8 of the 2026-10-18 ledger — this is that item's counterpart here):**
   the same row must also run the **while-in-use-only** case this ledger's §3 lists as
   never run — grant foreground location without the background grant, turn accessibility on, and
   expect an empty crash buffer. Without it a run can pass on the boot path and miss the live
   `AccessibilityMonitorService` / `CommandDispatcher` starts that #132 was about. Precondition: the
   agent is **paired**, or the decision returns `null` and the empty buffer proves nothing
   (`AccessibilityMonitorService.kt:262`).

   ```bash
   SERIAL=R5CW116Y6GF; PKG=com.familyshield.agent
   A11Y="$PKG/$PKG.services.AccessibilityMonitorService"   # full class name; short form dropped on One UI (TESTING.md:439)

   # record the two toggles this run changes, so the release can put them back (AGENTS.md §9.3)
   adb -s $SERIAL shell settings get secure enabled_accessibility_services
   adb -s $SERIAL shell settings get secure accessibility_enabled

   # while-in-use only: fine + coarse granted, background explicitly not
   adb -s $SERIAL shell pm grant  $PKG android.permission.ACCESS_FINE_LOCATION
   adb -s $SERIAL shell pm grant  $PKG android.permission.ACCESS_COARSE_LOCATION
   adb -s $SERIAL shell pm revoke $PKG android.permission.ACCESS_BACKGROUND_LOCATION
   adb -s $SERIAL shell dumpsys package $PKG | grep -E "ACCESS_(FINE|COARSE|BACKGROUND)_LOCATION"
   adb -s $SERIAL shell appops get $PKG FINE_LOCATION        # expect "FINE_LOCATION: allow"

   # nothing of ours in front, clear the crash buffer, then accessibility on (background bind)
   adb -s $SERIAL shell input keyevent KEYCODE_HOME
   adb -s $SERIAL logcat -b crash -c
   adb -s $SERIAL shell settings put secure enabled_accessibility_services "$A11Y"
   adb -s $SERIAL shell settings put secure accessibility_enabled 1
   adb -s $SERIAL shell settings get secure enabled_accessibility_services   # must echo the full name

   # two minutes, then: empty crash buffer, no LocationService, and the positive control
   sleep 120
   adb -s $SERIAL logcat -b crash -d                          # expect no com.familyshield.agent frame
   adb -s $SERIAL logcat -b crash -d | grep -c "com.familyshield.agent"        # expect 0
   adb -s $SERIAL shell dumpsys activity services $PKG | grep -c LocationService  # expect 0
   adb -s $SERIAL logcat -d -s AccessibilityMonitor | grep "not starting LocationService"
   #   expect "... not starting LocationService: background_location_missing ... (#132)"
   ```

   Pass means the lines above read as marked, plus the failed `locate_now` ack with
   `detail.reason = background_location_missing` in `/commands/history`. An empty crash buffer **with**
   `LocationService` running is not a pass — the FGS started, so the guard did not engage. Restore the
   two values read at the top of the block with `settings put secure enabled_accessibility_services
   "<value>"` / `settings put secure accessibility_enabled <0|1>` before the release (`AGENTS.md` §9.3
   asks for the previous values, not "left working"), and re-grant background location only if the run
   revoked it. The full step-by-step, including the parent-side `locate_now` send, is the 2026-10-18
   ledger's §4 item 8.

### Block C — the rest of the API, and the gates themselves

6. **#149 — the digest claim** (`0cc9cad`). Re-run the real-Postgres scratch story from the PR body
   (thrown → no row; transient → no row; permanent → one terminal row, provider called once; next day →
   sent). Cheap, and it is the only evidence that the silent-loss bug is gone.
7. **#150 — the probe checks for #124** (`4adc601`). Run the experiment the PR skipped: drop
   `requireOwnDevice` from `POST /:id/telemetry`, point the silence rule back at `active`, return the raw
   device row from `/push-token` — each must turn `G20`/`G22`/`N6e` red. A check nobody has seen fail is
   not yet a gate.

### Block D — UI

8. **#153 — QR pairing** (`69d1575`). `flutter test` (146) and `flutter analyze`, then the part no test
   covers: decode the QR with a reader and confirm `osra://pair?v=1&code=<digits>&host=<base>`; and
   decide whether the 5-minute first-run test stays open until the scanner exists.
9. **#145 — design tokens** (`2e6b5aa`). `flutter test` 134 and `analyze`, plus an eye on dark mode at
   320×568 on one screen. Nothing here can break another lane.

### Block E — docs-only, cheapest

10. **#143, #144, #148, #152, #154** — the §6.5 check is a diff read: every cited `file:line` says what
    the text claims. #143's three open conditions (§4.3, item 1), #154's acceptance (§4.2) and #144's
    `--pool=forks` trap (§4.3, item 4) are what a reader should fix while they are in there.
    `node scripts/check-docs-links.mjs` covers the links only.

## 6. The exact commands, on this machine

All paths are the ones this host uses. `127.0.0.1`, never `localhost` — the API binds IPv4 and a
`localhost` resolution to `::1` looks like a dead stack.

### 6.0 Secrets and the shared API

```bash
cd C:/KARIM/wt-<your-worktree>            # never the primary clone; never switch branches there
set -a; . /c/KARIM/tr-kimi/api-3000.env; set +a    # JWT_SECRET, INTERNAL_HMAC_SECRET, VAULT_KEY
curl -s http://127.0.0.1:3000/health/deep          # {"ok":true,…,"db":"up","redis":"up"}
```

The shared `:3000` is not yours to restart. If the change under test is not on `main`, run your own
instance and point `API_BASE` at it (§6.3). Never run two live gates concurrently, whoever owns them.

### 6.1 API unit suite and the static gates

```bash
pnpm install --filter "@familyshield/api..." --frozen-lockfile
pnpm --filter @familyshield/api test                         # vitest run — 361 expected at 4e56410
cd services/api && npx tsc --noEmit && cd ../..
node scripts/check-probe-integrity.mjs --base origin/main    # must print 0 removed or demoted
node scripts/check-docs-links.mjs                            # 0 broken (132 at 4e56410; 137 with this file)
```

In a **fresh worktree** the default vitest pool can time out on argon2 (`#144` measured
`4 failed | 11 passed` in `auth.test.ts`, 20 s each). That is the environment, not the diff; re-run with
`pnpm --filter @familyshield/api exec vitest run --pool=forks` and say which one produced the number.

### 6.2 Live gates against the shared `:3000`

One at a time, **≥ 60 s between them**. The probe's green summary grows with each probe PR (#150 left it
at **130**); quote the total you saw rather than trusting this line — what a green run must show is
`0 failed`, and e2e must show `69 passed, 0 failed`.

```bash
cd services/api
API_BASE=http://127.0.0.1:3000 node scripts/qa-probe.mjs
#   exit 0 = green; exit 2 = rate limited, wait 60 s and re-run; exit 1 = a real failure
sleep 65
DATABASE_URL="postgresql://familyshield@127.0.0.1:5432/familyshield" \
  API_BASE=http://127.0.0.1:3000 node scripts/e2e.mjs
#   without DATABASE_URL the erasure row-count check prints NOTE … skipped and is not evidence
```

### 6.3 A branch instance (when the change is not on `main`)

```bash
cd services/api
pnpm --filter @familyshield/api exec prisma generate
pnpm --filter @familyshield/api build                     # tsc → dist/
PORT=3100 JOBS_ENABLED=0 DATABASE_URL="postgresql://familyshield@127.0.0.1:5432/familyshield" \
  node dist/server.js                                      # shares Postgres/Redis; do not touch :3000
# in a second shell, from services/api, with the env from §6.0:
API_BASE=http://127.0.0.1:3100 node scripts/qa-probe.mjs
sleep 65
DATABASE_URL="postgresql://familyshield@127.0.0.1:5432/familyshield" \
  API_BASE=http://127.0.0.1:3100 node scripts/e2e.mjs
# then stop the :3100 process before you do anything else
```

This is the shape #147 used (`:3100`, gate `124/0`) and #156 used (`:3017`, gate `130/0`). A gate run
against `:3000` while your branch is not deployed is a regression check on `main`, not evidence for the
PR — say which stack you used.

### 6.4 Flutter (parent app)

```bash
cd apps/parent-app
C:/KARIM/tools/flutter/bin/flutter pub get
C:/KARIM/tools/flutter/bin/flutter analyze
C:/KARIM/tools/flutter/bin/flutter test          # 146 expected at 4e56410
```

### 6.5 Android (both flavours) and the merged-manifest gate

`--no-daemon` is not optional here: the Gradle daemon survives across flavours and a stale daemon is one
of the reasons a "green" report can be a report about a different tree.

```bash
cd apps/child-android
export ANDROID_HOME=C:/KARIM/tools/android-sdk
export JAVA_HOME=C:/KARIM/tools/jdk-17
./gradlew testPlayDebugUnitTest testFullDebugUnitTest assemblePlayDebug assembleFullDebug --no-daemon
# per-flavour totals are the sums over app/build/test-results/test<Flavour>DebugUnitTest/*.xml
#   (42 suites / 267 tests / 0 failures per flavour at 4e56410)

# the merged-manifest assertion (#157) — must exit 0 here, and MUST exit 1 on a doctored XML
cd ../..
node scripts/check-merged-manifest-gate.mjs
#   > merged-manifest gate: 2 result set(s) checked, all assertions ran and passed
#   > exit=0
```

The gate reads `apps/child-android/app/build/intermediates/merged_manifests/<flavor>Debug/**/AndroidManifest.xml`,
which the unit-test tasks now depend on. A run that prints `no test results — did the unit-test task run?`
means the artefact was absent, not that the gate passed.

### 6.6 Windows agent (xunit) — unchanged, not touched by this batch

```bash
cd apps/agent-desktop
C:/KARIM/tools/dotnet/dotnet.exe test tests/FamilyShield.Agent.Tests
```

Beware the two documented traps: the real `LockWorkstationAction` locks your session if it is not
stubbed, and an install with no PIN refuses to arm by design.

### 6.7 Hardware (only with the lease)

```powershell
.\scripts\hardware\phone-claim.ps1 -Action Claim -Owner "<agent>" -Purpose "TR-21 row 3 / #155 ack row"
.\scripts\hardware\phone-claim.ps1 -Action Status
```

Post the lease line on the board (`AGENTS.md` §9.2), and release with `-LeftState` after clearing every
restriction (§9.4). The **keyguard PIN is the human's**; the app PIN is the maintainer's to rotate
(issue #151) and is never a keyguard credential. The phone is `R5CW116Y6GF` and it is idle — a free phone
is not an invitation (§9.1).

### 6.8 Cleanup — do this whether the run passed or failed (`AGENTS.md` §7)

```bash
C:/KARIM/tools/pg/pgsql/bin/psql.exe -h 127.0.0.1 -U familyshield -d familyshield \
  -f services/api/scripts/cleanup-test-data.sql                        # dry run
C:/KARIM/tools/pg/pgsql/bin/psql.exe -h 127.0.0.1 -U familyshield -d familyshield \
  -v apply=1 -f services/api/scripts/cleanup-test-data.sql             # applies; expect "OK: 1 family"
node services/api/scripts/cleanup-test-redis.mjs                       # dry run
node services/api/scripts/cleanup-test-redis.mjs --apply
```

Expected end state: one family (`Demo Family`), child `Alex`, device `Pixel 7a`, nothing else. #156's
counter key (`auth:session-version:<parentId>`) is deliberately TTL-less and is reaped by
`cleanup-test-redis.mjs` only when the `Parent` row is gone — if you see a persistent one, check whether
its parent still exists before deleting it.

## 7. What this ledger is not

- **Not a re-verification.** No gate in §3 was re-run to write this file. The only commands I ran for it
  are `node scripts/check-docs-links.mjs` (output in the PR's gate section), `git log`/`git show` for the
  merge shas, times, heads and message text, `git diff --stat` for the docs-only claims, and the
  `grep`/`sed` reads of `digestScheduler.ts`, `.env.example`, `qa-probe.mjs`, `sessions.ts`,
  `TESTING-STRATEGY.md` and `TEST-REQUESTS.md` that back the "paid" verdicts in §4. The **2026-10-19
  amendments** (§4.3 item 1, §4.4, Block B item 5) add no run: they are the `file:line` re-reads at
  `1733d83`, the PR/issue records they name, and one `grep -rnE 'app PIN [0-9]{4}'` over `docs`/`scripts`.
- **Not a status upgrade.** All 13 rows are `author-run` because that is what the records say. The two
  non-author records in the batch are quoted with their timestamps so a reader can see what they were:
  a conditional approval whose conditions did not land (#143) and an acceptance that arrived after the
  merge (#154). The **conditions** of that approval landed as dated record amendments on 2026-10-19
  (§4.4) — that closes the approval's asks, not the verification gap: every #155/#156 row stays
  `author-run`.
- **Not a substitute for a `TR-*` row.** When a verifier does re-run a row above, the record belongs in
  [`TEST-REQUESTS.md`](TEST-REQUESTS.md) as its own request with raw output, and this file can then cite
  it — that is the file working, not this one going stale.
- **Not the last word on the 2026-10-18 UTC day.** Yesterday's ledger holds merges 1–31 and this one
  holds 32–44; the pair is the day, and neither alone is. *(second half)* That statement is about the
  2026-10-18 UTC day only: the file as a whole now holds **62 merges** (`603a33d` → `025be5b`, 31 + 13 +
  18), because the 2026-10-19 local day runs to `05:43:16Z` — see §8 and §15's last bullet.

## 8. The second half — what this refresh covers, and why it is 18 merges

**Written 2026-10-19 10:10 +0400 (06:10Z), same author, same rules.** §3's rows stop at #155
(`4e56410`, 2026-10-18 20:00:18Z) because that was `origin/main` when this file was written. The day did
not stop there:

| Reading | Range | Merges |
|---|---|---|
| local (+0400) | 2026-10-19 00:43:19 → **09:43:16** | 18 |
| UTC | 2026-10-18 **20:43:19Z → 2026-10-19 05:43:16Z** | 18 |
| `git log --first-parent --format='%h %s' 4e56410..origin/main` | — | **18** |

`--first-parent` returns exactly 18 and every one is a PR merge; the `merge: main into <branch>` syncs
(#169's, #171's and others) live inside their PR branches and have no row, as in §1. This half is
honestly the *tail of the UTC day plus the local morning*, not a second calendar day — the same
boundary trap §1 records, one layer along.

Two of the eighteen were already **named** in this file without a row: #164 (`e202c9e`) and #171
(`1733d83`), cited by §4.4's dated amendments. They get rows below because a citation is not a row: a
reader asking "who ran what on #171" found only *"Read at `1733d83`"* inside a paragraph about #143.
#160 (`14cf3c3`) is this file's own merge and #173 (`f777104`) is the PR that wrote §4.3/§4.4 into it;
both are listed, because the ledger's own PRs are not exempt from the ledger.

Checked and not duplicated: **#145** (design tokens, 3.8) is already §3's row and Block D item 9 and no
later merge touched it; **#161** (localization, 3.1) is new here.

## 9. The 18 merges

Sorted by merge time (UTC). Quotations are verbatim from `git log -1 --format=%B <sha>`, trimmed with
`…` where marked. "Head" is the second parent — the sha the numbers should belong to. **Dates, so the
time-only cells cannot be misread:** the UTC date is **2026-10-18** up to and including `1733d83`
(23:49:33Z) and **2026-10-19** from `efc8e35` (01:09:02Z) — a different window from the local (+0400)
date, which is 2026-10-19 for all 18. Every cell's local time is on 2026-10-19.

| PR | Title | Merged as (UTC · local) | Head | Who ran what · exact numbers claimed | Status |
|---|---|---|---|---|---|
| [#160](https://github.com/handfulofluck-lab/osra/pull/160) | docs(qa): verification ledger 2026-10-19 and the close-out of yesterday's debts | `14cf3c3` 20:43:19Z · 00:43:19 | `430711b` | **Kimi (author, docs).** *"Docs-only; links 0/137."* | author-run |
| [#161](https://github.com/handfulofluck-lab/osra/pull/161) | feat(parent-app): localization — English and Arabic with real RTL (3.1, first slice) | `40f4f61` 20:43:26Z · 00:43:26 | `ef96b54` | **Kimi (author).** *"Evidence at ef96b54 (CI 7/7): flutter test 158 passed (146 before + 12), analyze clean."* Nine Arabic screens at 320×568 assert no layout exception; the audit found a 12 px overflow in the child-detail app bar and fixed it. Gaps stated: no native-speaker review (that is 3.1's acceptance, issue #159), consent notice left English, four screens untranslated | author-run |
| [#162](https://github.com/handfulofluck-lab/osra/pull/162) | fix(api): `/token/refresh` cannot outrun a revocation; a failed revocation no longer reports success (#158) | `e9339f0` 21:01:33Z · 01:01:33 | `3920307` | **Kimi (author).** *"Evidence at 3920307 (CI 7/7): vitest 363 passed; fail-before on origin/main is exactly the two shapes he predicted (expected 1 to be 0 for the parked-revocation case, and a promise that resolved instead of rejecting for the fail-open); probe 130/0 and e2e 69/69 on a spare :3110 (another lane held :3100), DB restored; probe-integrity unchanged."* Both findings are Claude's, from his review of #156 | author-run |
| [#163](https://github.com/handfulofluck-lab/osra/pull/163) | docs(qa): row 3 asserts the accepted silence definition; TR-22 measures it PASS | `4017b89` 21:35:59Z · 01:35:59 | `bb2489e` | **Kimi (author, hardware on the Flip4).** *"Measured on the Flip4 with DEVICE_SILENT_MINUTES=5 and JOBS_ENABLED=1 on a spare instance: after am force-stop, the old expectation still reads False after 122 s (NOT gated), and the accepted assertion produced exactly one critical tamper/device_silent alert with Device.status offline. PASS, recorded as TR-22."* No unit or probe count in the merge message. `TESTING-STRATEGY.md` §3a stops saying PROPOSED | author-run (hardware) |
| [#164](https://github.com/handfulofluck-lab/osra/pull/164) | fix(scripts,docs): the test app PIN is no longer published; the probe requires `-Pin` (#151, redaction half) | `e202c9e` 21:47:24Z · 01:47:24 | `3b14e8f` | **Kimi (author, docs + one script parameter).** *"Docs-only plus one script parameter; links 0/137, CI 7/7."* Claude's review arrived **1 m 47 s after** the merge and asked for three changes; the `Mandatory` one is still unapplied (§12). Rotation deliberately not done — #151 open | author-run — reviewed after the merge, conditions unlanded |
| [#168](https://github.com/handfulofluck-lab/osra/pull/168) | fix(api): the silence window is validated against the agent's telemetry cadence (#166) | `e3fbe9b` 22:25:52Z · 02:25:52 | `e507f1c` | **Kimi (author).** *"Evidence at e507f1c (CI 7/7): vitest 369 passed (six new cases, including a parity test that reads both Kotlin cadence constants so the server cannot drift from the agent), probe 130/0 and e2e 69/69 on a spare :3416, DB restored, docs links 0/137."* Default 30 unchanged; a tighter override is clamped with a startup warning; `DEVICE_SILENT_ALLOW_TIGHT=1` keeps TR-22's 5-minute run possible | author-run — Claude's post-merge read **accepted** the design choice, and said the re-run is "for a tester" |
| [#169](https://github.com/handfulofluck-lab/osra/pull/169) | fix(android): launcher, system UI and dialer are exempt from every block policy (#165) | `434f67b` 22:33:51Z · 02:33:51 | `9127b4d` | **Kimi (author).** *"Evidence at 9127b4d (CI 7/7 after merging main): 297 tests per flavour, 0 failures; fail-before reproduced (8 of 12 new tests fail on the pre-fix gate)."* Hardware **not** run and said so: the cleanup needed the app PIN, which #164 had just removed from the repo | author-run — post-merge review accepted the design with two open items (§12) |
| [#171](https://github.com/handfulofluck-lab/osra/pull/171) | fix(android): the block decision uses the window in front, not the event's package (#165) | `1733d83` 23:49:33Z · 03:49:33 | `69767d8` | **Kimi (author, hardware on the Flip4).** *"Gates: 303 tests per flavour, 0 failures; merged-manifest gate passes; red before the change (the new test does not compile on 434f67b, which is the honest fail-before for an API that did not exist)."* Hardware: *"Home leaves com.sec.android.app.launcher focused at 2 s and 6 s; ACTION_DIAL reaches Samsung's dialtacts at 2 s and 6 s"*, Chrome still blocked, Home from the overlay at 2/6/14 s | author-run — **merged 2 m 36 s after a review that required two changes** (§12) |
| [#173](https://github.com/handfulofluck-lab/osra/pull/173) | docs(qa): Claude's three conditions on #143, closed as dated amendments | `f777104` 01:19:37Z · 05:19:37 | `3b255d8` | **Kimi (author, docs).** *"Docs-only, links 0/139."* Append-only (this file's §4.3 item 1, §4.4, Block B item 5) | author-run |
| [#174](https://github.com/handfulofluck-lab/osra/pull/174) | fix(android): debug builds clean up without the app PIN; release keeps the hard admin (#170) | `0313e01` 01:19:43Z · 05:19:43 | `186e2b0` | **Kimi (author, hardware on the Flip4).** *"Evidence at 186e2b0 (CI 7/7 after merging main): 307 tests per flavour, merged-manifest gate passes, fail-before reproduced by moving the overlay to src/release (2 failures) and by deleting the release merged manifests (checker exit 1)."* Hardware with no PIN held: *"dumpsys device_policy shows testOnlyAdmin=true, dpm remove-active-admin exits 0, adb uninstall succeeds"* | author-run — **merged 33 min after a review that required two changes** (§12) |
| [#177](https://github.com/handfulofluck-lab/osra/pull/177) | test(parent-app): the social timeline test stops depending on the wall clock (#176) | `efc8e35` 01:09:02Z · 05:09:02 | `0d563d1` | **Kimi (author, test-only).** *"Reproduced at 00:55Z and fixed at 00:58Z, with CI's parent-app job green at 01:08Z - inside the window, which is the only evidence that matters."* No suite count. Honest note: the 23:59 boundary case passes on the old fixture too, so it is an edge guard, not a second fail-before | author-run |
| [#179](https://github.com/handfulofluck-lab/osra/pull/179) | feat(3.2): the child app scans the parent's pairing QR | `df7c89e` 02:08:16Z · 06:08:16 | `7a39b3c` | **Kimi (author, hardware + JVM).** *"Evidence at 7a39b3c (CI 7/7): 330 tests per flavour, 0 failures; 13 parser cases and 7 state-machine cases; merged-manifest gate passes and fails when CAMERA is removed from a doctored merged manifest (2 assertions)."* Hardware: install, rationale, OS prompt, camera-ready status, accessibility labels and the denial fallback verified; typed pairing then completed end-to-end. **Scan → review → confirm not exercised** (camera covered); 5-minute test untouched (§11) | author-run — the claim half the PR is about is hardware-blocked |
| [#180](https://github.com/handfulofluck-lab/osra/pull/180) | feat(api): one-time MFA recovery codes (ADR-0023 Option A, technical half) | `37ad743` 03:15:47Z · 07:15:47 | `7f857df` | **Kimi (author).** *"Evidence at 7f857df (CI 7/7): vitest 381 passed across 33 files; probe 141/0 including O1-O11 on a spare :3123; e2e 69/69; probe-integrity 12 added, 0 removed; migration 0017 is additive and applied."* Optional B untouched; no UI in this PR | author-run — **merged 29 min after a review whose first item "defeats the design"** (§12, issue #183) |
| [#182](https://github.com/handfulofluck-lab/osra/pull/182) | docs(qa): pairing time measured on hardware (21 s proxy, not the 5-minute acceptance) | `44d8712` 03:26:21Z · 07:26:21 | `4ac057d` | **Kimi (author, hardware).** *"The number is 21.2 s median over three clean installs, of which ~14.6 s is the harness's own uiautomator polling and ~0.65 s is machine typing"*; `pair/claim` 5.7–9.7 ms; *"links 0/139; CI 7/7."* The run found #181 (the sheet) rather than a number worth passing | author-run (hardware, proxy) |
| [#185](https://github.com/handfulofluck-lab/osra/pull/185) | docs: #181 diagnosed — Samsung Knox keeps a stale admin row, and our own cleanup created it | `157f477` 04:09:20Z · 08:09:20 | `72eed2d` | **Kimi (author, hardware).** *"Evidence: logcat with the Knox stack, dumpsys before/after, decompiled Knox excerpts, and the three hypotheses ruled out with measurements (tap target, testOnly build, intent). No product code changed because there is no app-side bug to fix."* The measurement is reproducible from `docs/TESTING.md:555` | author-run — a diagnosis, not a gate; **it blocks other rows** (§11) |
| [#184](https://github.com/handfulofluck-lab/osra/pull/184) | feat(parent-app): MFA enrolment, show-once recovery codes, lost-authenticator recovery | `64679ad` 04:09:27Z · 08:09:27 | `a26d657` | **Kimi (author).** *"Evidence at a26d657 (CI 7/7): flutter test 184 passed (24 new), analyze clean; all ~59 new strings exist in both en and ar, and the ARB parity test stays green."* Declared gap: *"the shared :3000 predates #180, so the client shapes are those asserted by the merged API tests, not a live observation"* | author-run — the live half was **not run** and the PR says so |
| [#187](https://github.com/handfulofluck-lab/osra/pull/187) | feat(android): removal tries Knox first on Samsung, falls back to AOSP; enrolment names the stale state | `8f61d4e` 04:37:30Z · 08:37:30 | `c4601d9` | **Kimi (author).** *"Evidence at c4601d9 (CI 7/7): 344 tests per flavour, merged-manifest gate green."* 14 unit tests: Knox only when the probe finds a callable API, fallback on missing class/method/reflection/SecurityException **and** on "Knox says success but the admin is still active". AC1 explicitly **not** met and hardware-blocked | author-run — AC1 blocked (§11); a post-merge review found a new defect, #188 |
| [#189](https://github.com/handfulofluck-lab/osra/pull/189) | feat(parent-app): a guided first run — sign in, add child, pair, done (3.2) | `025be5b` 05:43:16Z · 09:43:16 | `a4080c8` | **Kimi (author).** *"Evidence at a4080c8 (CI 7/7): flutter test 202 passed (184 before + 18 new), analyze clean. The API was not touched and no endpoint was missing."* Wizard with resume, no skippable sign-in, "Finish setting up · Pair now" card; every step has an Arabic RTL test at 320×568. *"Not claimed: the timed five-minute human test and the child-side scan -> confirm on hardware"* | author-run |

**Totals for this half: 18 merges — 0 tester-verified, 18 author-run, 0 with no run at all.** Fifteen
touched a non-Markdown file (code, tests, a hardware script or a probe); three are docs-only: #160,
#173 and #185 — and #185 is a diagnosis with no product change behind it.

Claims inside these PRs that **no one has run**, named so a reader does not assume otherwise:

- **#180** — the window between `/mfa/recover` and re-enrolment. `O1`–`O11` cover replay, sibling codes,
  concurrent claims, the token's scope and *post*-re-enrolment login; **none of them logs in with only
  the password after a recovery**, which is where the account is password-only (issue #183).
- **#171** — a blocked app that is **visible but not active**: picture-in-picture and split screen
  (issue #175). No test, JVM or hardware.
- **#174** — that a `testOnly` debug admin does not stand in for the release build in the tamper rows
  (issue #178). The hardware probe does not even read `testOnlyAdmin` today.
- **#169/#171** — the `com.familyshield.` prefix exemption in `EssentialPackages.isEssential`
  (`EssentialPackages.kt:65-77`): a sideloaded `com.familyshield.unblock` is exempt from every block.
  Raised in the post-merge review of #169; **no issue tracks it**.
- **#187** — AC1 (remove → reinstall → activate through the sheet) on a phone whose Knox registry is
  clean: blocked (§11). AC3's user-facing half is JVM-proven only.
- **#179**, **#182**, **#189** — the scan → review → confirm path on a phone, and roadmap 3.2's timed
  five-minute non-engineer first run. TR-23 is a 21.2 s proxy and says so.
- **#184** — every MFA screen against a **live** API. The client shapes came from the merged API tests;
  the server reachable during the PR predated #180.
- **#161** — Arabic by a native speaker (3.1's acceptance, issue #159), and the four untranslated screens.

## 10. What this half does to §4's debts

| §4 item | Verdict after this half |
|---|---|
| **4.1 #5 — "no merge message names a verifier, a `TR-*` row or a verification sha"** | **Unchanged, and now with a worse variant.** Still no verifier line in any of the 18. What is new is that a non-author review sometimes *did* arrive first — and the merge went ahead with its required changes open (#171, #174, #180) or arrived 1–2 minutes after the merge (#164). §12 is that table |
| **4.1 #7 — "the UI-only PRs rest on widget tests"** | **grew by three**: #161 (158), #184 (184), #189 (202). #184 additionally declares that no live API was reachable; #189's acceptance is a human test nobody has run |
| **4.2 — "a decision that exists only as a comment"** | **paid.** #163 made `TESTING-STRATEGY.md` §3a read ACCEPTED and the probe measure the accepted definition; the 120-s measurement survives as a non-gating NOTE |
| **4.2 — #146's MFA takeover, `G19` has only the author's run** | still open, and the surface around it grew: #180 adds `/mfa/recover`, `/mfa/recovery-codes` and a 15-minute purpose token, all on the same `requireJwt` purpose rule. `G19` is still one run, the author's |
| **4.2 — "the app PIN published in a repo doc"** | redaction **paid** (#164); rotation still open (#151). The review's `Mandatory = $true` item did not land (§12), so a run that forgets `-Pin` still **hangs** instead of failing |
| **4.3 #4 — "#144's standard gate was never green where it was written"** | unchanged; no later PR re-tested the default vitest pool in a fresh worktree |
| **4.3 #5 — "#150's checks have never been shown to fail"** | unchanged; still nobody's experiment |

## 11. What is now **blocked** on hardware, not pending

The distinction matters, because a reader who sees "open" on these rows will schedule them and lose a
day. Each of these needs something the programme does not currently have; none of them is waiting for
work to be done.

### 11.1 The Flip4 (`R5CW116Y6GF`) carries a stale Knox admin row — so nothing needing device admin runs on it

#185 measured it: Samsung keeps its own admin registry (`EnterpriseDeviceManagerService`,
`mAdminList`/`mAdminMap`) that AOSP's `removeActiveAdmin` does not clear, and this repo's documented
cleanup for debug builds (`adb shell dpm remove-active-admin`, the #170 route) is itself what creates
the row. The row survives `pm uninstall` and reinstall with a **new uid**, because the match is
component + user. `Activate` on the system sheet then throws
`IllegalArgumentException: Admin is already added`, the sheet closes, and the app lands on
`⚠️ Protection: alert-only`. Clearing it needs the Knox removal path *while the component is active*
(blocked by the very defect), root, or a factory reset — a maintainer decision. Full detail, with the
logcat to grep for, is `docs/TESTING.md:555`.

Consequences, stated as the labels the rows should carry:

| Row | What it needs | Why it cannot run now |
|---|---|---|
| #187 **AC1** (remove → reinstall → activate through the sheet) | a Samsung phone whose Knox registry is clean for `com.familyshield.agent/.security.FamilyShieldDeviceAdmin` | the Flip4's registry is permanently stale for that component until root/factory reset (#185). **Blocked — hardware** |
| Phase 1 tamper rows — probe rows 1, 2, 10 (`adb uninstall`, `pm clear`, deactivate admin) and the Settings force-stop guard | a live Device Admin from the real UI | no admin can be activated on the Flip4 at all since the sheet started failing. TR-22's row 1 PASS (2026-10-18 21:06Z) predates the stale row and is not repeatable there. **Blocked — hardware** |
| #186's and #188's enrolment states | a Samsung phone where the sheet can complete and where it can be cancelled | the stale row prevents the first; #188 is about the second and is JVM-only. **Blocked — hardware** |
| #179 **scan → review → confirm** | an unobstructed rear camera | the phone's camera is covered in its test position (#179's own PR says so). The parser and state machine are JVM-tested (13 + 7); the acceptance step is not reachable. **Blocked — physical** |
| Roadmap **3.2** — the timed **five-minute non-engineer first run** | a human who has not seen the flow, a working camera, **and** a successful device-admin activation | blocked twice: the camera (§11.1 row above) and the admin row. TR-23 (`#182`) is a 21.2 s proxy that models no reading, no typing and no parent-app step, and reached device admin in **0 of 3** runs. **Blocked — human + hardware** |

Two compounding facts a planner should read together:

- **#178 (open, from #174's review):** since #174 every debug build is `testOnly`, so its admin is a
  *test* admin and the tamper rows measured on it are **not gate evidence** for the release build. The
  only builds that can be cleaned up without the app PIN are exactly the ones whose tamper results do
  not count.
- **The release build cannot substitute on this host**: it is HTTPS-only (`cleartextTrafficPermitted`
  false, TR-18), and there is no HTTPS API endpoint here.

So the Phase 1 tamper gate has **no reachable measurement path on this hardware**: the debug build is
not evidence, the release build cannot talk to this host, and neither can activate an admin on the
Flip4. That is a hardware/decision problem for the maintainer, not a backlog item for a tester.

### 11.2 What is still **pending** (and therefore a fair ask)

- #155's `locate_now` failure ack and the while-in-use-only case (Block B item 5 in §5) — needs pairing,
  which works; no admin required.
- TR-22 row 3's re-run with `DEVICE_SILENT_ALLOW_TIGHT=1` (#168) — software + a 10-minute wait.
- Every API and JVM row in §13 — no hardware at all.
- #179's scan path becomes pending again the moment the phone is off the mount.

## 12. The reviews that arrived — and what the tree still does not do

This is the half's most uncomfortable finding, and it is checkable in four greps. Claude reviewed five
of these PRs. Three reviews arrived **before** the merge and named required changes; every one of those
merges shipped without them, and the merge messages do not mention the review at all. The changes were
then filed as issues — which is the right place for them — but a reader of `git log` sees a clean merge.

| PR | Review vs merge | What the review required | In the tree at `025be5b`? | Tracked by |
|---|---|---|---|---|
| #164 | review 21:49:11Z, merge **21:47:24Z** — review 1 m 47 s **after** | `-Pin` must not be `Mandatory` (a forgotten flag hangs a non-interactive run); default `$Pin = $env:OSRA_TEST_APP_PIN`, and fix two doc commands that omit it | **No.** `scripts/hardware/android-bypass-probe.ps1:23` and `android-pairing-time.ps1:16` still read `[Parameter(Mandatory = $true)][string]$Pin` | **nothing** |
| #171 | review 23:46:57Z, merge 23:49:33Z — **2 m 36 s later** | (1) judge every **visible** window, not only the active one — the PiP/split-screen bypass — via a pure `blockCandidates(...)` + cases; (2) recycle `rootInActiveWindow` | **No.** `AccessibilityMonitorService.kt:76-96` decides from `resolveForeground`/`rootInActiveWindow` alone, and `:127` reads it without recycling (so does the tamper guard at `:191`) | [#175](https://github.com/handfulofluck-lab/osra/issues/175) (PiP, open); recycling half **untracked** |
| #174 | review 00:46:23Z, merge 01:19:43Z — 33 min later | (1) the hardware probe must label tamper rows `PASS (debug/testOnly — not gate evidence)` and TESTING-STRATEGY must say the tamper gate counts only on a release-signed build; (2) a release-APK `testOnly` guard in the release checklist | **No.** `grep -n testOnly scripts/hardware/android-bypass-probe.ps1 docs/QA/TESTING-STRATEGY.md docs/RELEASING.md` → nothing. `docs/TESTING.md:31,600-610` describes the mechanism, not the evidence limit | [#178](https://github.com/handfulofluck-lab/osra/issues/178) (open) |
| #180 | review 02:46:11Z, merge 03:15:47Z — 29.5 min later | (1) *"the first defeats the design"*: after recovery a password-only `/login` must not return a session — model `mfa_reenroll_required`; (2) bump the sessions version **before** the transaction so a failed revocation does not spend the code | **No.** `services/api/src/routes/auth.ts:210` asks for a TOTP only `if (parent.mfaEnabled)`, and `:495` sets `mfaEnabled: false`; `:502` calls `revokeAllRefreshTokens` **after** the commit, and it throws since #162 (`services/api/src/lib/sessions.ts:114`). ADR-0023:82 calls the result "the password-only window" and bounds it, which is the disagreement, not a fix | [#183](https://github.com/handfulofluck-lab/osra/issues/183) (open, `security/high`) |
| #187 | merge 04:37:30Z, review **after** | post-merge: `AdminEnrolmentPolicy.classify` returns `STALE_KNOX_ADMIN` whenever the sheet returned, AOSP reports no admin **and** a Knox API is present — which on Samsung is always, so every **cancelled** activation shows the stale-state screen | The finding is about the merged code and is true of it | [#188](https://github.com/handfulofluck-lab/osra/issues/188) (open) |
| #169 | merge 22:33:51Z, post-merge review | `EssentialPackages.isEssential` exempts any `com.familyshield.` prefix — the same name-spoof class #169 removed for `.dialer`/`.telecom` | **Yes, still there:** `apps/child-android/app/src/main/java/com/familyshield/agent/enforcement/EssentialPackages.kt:65-77` | **nothing** |

Reproduce the four headline claims in one sitting, no phone and no stack:

```bash
grep -n "Mandatory = \$true" scripts/hardware/android-bypass-probe.ps1 scripts/hardware/android-pairing-time.ps1
grep -n "rootInActiveWindow" apps/child-android/app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt
grep -n "if (parent.mfaEnabled)" services/api/src/routes/auth.ts          # :210 - no re-enrol state exists
grep -n "OWN_PREFIX" apps/child-android/app/src/main/java/com/familyshield/agent/enforcement/EssentialPackages.kt
```

**What this section does not say.** It does not say the merges were wrong to land: #171's diagnosis was
right and fixed a real defect, #180 is reachable-by-API-only and #184 makes it usable, and each finding
has an issue with a repro. It says the **evidence trail** reads as if the reviews agreed, and §6.5(3)
asks a merge message to name what verified it. Here the honest line would have been *"merged with
#183 open; the recovery half is API-only and the UI half ships in #184"* — one sentence, and the next
reader would not have to reconstruct this table.

## 13. The re-run list for this half, in risk order

Same rule as §5: **one live gate at a time, ≥ 60 s apart**; the shared `:3000` rate-limits at 200 req/min
and a second concurrent gate aborts with exit 2 (the #114/#129 contract, not a failure). Nothing in §5 is
withdrawn — this block is additive, and the session-counter row of §5 Block A item 1 is still the first
thing to re-run in the **first** half.

### Block A — the API surfaces this half adds (highest risk first)

1. **#180 — MFA recovery** (`37ad743`). The riskiest change in the batch: two endpoints a caller reaches
   with email + password + a one-time code, a purpose-scoped token, and a state change that removes the
   second factor. Reproduce the author's `141/0` (O1–O11) on a branch-built server, then test the two
   things the review says are wrong — **as evidence for #183, not as a regression hunt**:

   ```bash
   # 1. recover, then log in with the password alone - today this returns a full session
   curl -s -XPOST http://127.0.0.1:3100/v1/auth/mfa/recover -H 'content-type: application/json' \
     -d '{"email":"<acct>","password":"<pw>","code":"XXXX-XXXX-XXXX-XXXX"}'
   curl -s -XPOST http://127.0.0.1:3100/v1/auth/login -H 'content-type: application/json' \
     -d '{"email":"<acct>","password":"<pw>"}' | jq 'has("token")'     # #183 says: expect no session
   ```

   Pass for a **fix** is `401 {"error":"mfa_reenroll_required"}` and a recovery token, and `token`
   absent. What the tree does today is a full parent session: `routes/auth.ts:210` + `:495`.
   Second: make `incrby` reject and confirm a retry with the same code still works (today the code is
   spent and the caller gets a 5xx — `routes/auth.ts:502` after the transaction). Then the invariant
   that must not move: the recovery token still gets `401` on `/family/me`, `/logout-all` and
   `/mfa/recovery-codes` (probe `O7`).
   *Apply migration `0017_parent_mfa_recovery_codes` before any of this* — a server built from a
   checkout without it answers 500 on `/mfa/recover`, which is not a finding.

2. **#162 — the refresh record is bound to the session counter** (`e9339f0`). Every refresh record carries `sv`
   now (`routes/auth.ts:133-137`), `/token/refresh` refuses one below the current version and refuses a
   record with no `sv` at all (`:580-610`), and the revocation bump is no longer best-effort
   (`lib/sessions.ts:114-129`, which is what makes #183's ordering bug a 5xx). Test: log in, keep the
   refresh token, `POST /v1/auth/logout-all`, then refresh → `401`; and a record written before #158
   (no `sv`) → `401`, forced re-login, **not** verified against the legacy epoch. This closes the
   "rolling-deploy window" question §5 Block A item 1 raises.

3. **#156's session counter, same-second case with no sleep** — carried unchanged from §5 (Block A item 1). Still nobody's
   run but the author's.

4. **#139's residual** (a co-parent token on a sibling family → `403`) — carried unchanged from §5.

### Block B — the Android gate, and the block decision

5. **#174 — the `testOnly` half of the merged-manifest gate** (`0313e01`). The gate now expects **10
   named assertions across two classes** — Play 6, Full 4 — of which four are `testOnly`
   (`scripts/check-merged-manifest-gate.mjs:40-55`). Verify it can **fail**, in the shape #157 taught:
   put `android:testOnly="true"` in a release source manifest and watch
   `play/full release merged manifest is not testOnly` go red; delete a release merged manifest and
   confirm `MergedManifestLocator.require` fails rather than skipping
   (`apps/child-android/app/src/test/java/com/familyshield/agent/manifest/MergedManifestLocator.kt:50`).
   Then decide Claude's unlanded item (#178): the hardware probe still cannot say *"not gate evidence"*.

6. **#171 / #169 — what the block decision evaluates** (`1733d83`, `434f67b`). Two rows, one JVM and one
   hardware, both about a claim the code does not make today:
   - **PiP / split screen** (#175): bedtime active, start a video, press Home. Does the overlay come up
     for `com.google.android.youtube`? Does the PiP keep playing on top? Record both — the review asked
     for the second measurement too, and "keeps playing" is a decision for the maintainer, not a failure
     of the run.
   - **`com.familyshield.` prefix** (`EssentialPackages.kt:65-77`): sideload a package named
     `com.familyshield.unblock` with a launcher icon and confirm it is **blocked** during bedtime.
     Today it is exempt. This is the cheapest real bypass in the tree.

7. **#179 — the scanner** (`df7c89e`): reproduce 330 tests per flavour and the 13 + 7 cases, and run
   scan → review → confirm on a phone off the mount. Blocked on hardware today (§11); the JVM half is not.

8. **#187 / #188 — the Knox removal policy** (`8f61d4e`): 344 tests per flavour reproduce; AC1 is
   blocked (§11). The cheap independent read is the **fallback** claim, which needs no phone: "Knox
   claims success but `DevicePolicyManager` still reports the admin active" must land on AOSP removal —
   that is a unit test, and a reviewer can read it at
   `apps/child-android/app/src/main/java/com/familyshield/agent/security/AdminRemovalPolicy.kt:46`.

### Block C — the rest of the API and the jobs

9. **#168 — the silence floor** (`e3fbe9b`): re-run TR-22 row 3 with the flag the merge added —
   `DEVICE_SILENT_ALLOW_TIGHT=1 DEVICE_SILENT_MINUTES=5` — on a server built from `main` after #168. The
   clamp-and-warn path is unit-tested; the 5-minute measurement has only the author's run, and #168's
   review asked for exactly this re-run at the merged sha.

10. **#150's mutation experiment** — still owed from §5 Block C item 7, unchanged by this half.

### Block D — UI, cheapest to run, lowest blast radius

11. **#189** (`025be5b`) — `flutter test` 202 expected; **#184** (`64679ad`) — 184 expected, and the live
    gap it declared is now closable (a server built from `main@025be5b` **has** #180; at the time of the
    PR the process on `:3000` did not). Walk enrol → show-once → recover against that server.
12. **#161** (`ef96b54`) — 158 expected. 3.1's acceptance is a **native-speaker review of the Arabic
    screenshots** (issue #159); a tester cannot sign it off, only the maintainer or a native speaker can.

### Block E — docs-only, a diff read

13. **#160, #173, #182, #185, #164** — the §6.5 check is a diff read: every cited `file:line` must say
    what the text claims. While in there, fix the staleness the §8 boundary exposes:
    `docs/ROADMAP.md:90` still says 3.1 is *"unmerged as of 2026-10-19"* (merged `40f4f61`), `:91` still
    says the wizard is *"unmerged"* with *"no merge sha yet"* (merged `025be5b`), and `:92` still says
    #180's *"independent verification and merge sha still owed"* (merged `37ad743`). A citation that no
    longer resolves is a documentation bug (`AGENTS.md` §8) — and row 3.2's "in progress" is correct
    while 3.1's "unmerged" is not.

## 14. The counts moved — use these, not §6's

§6's numbers were true at `4e56410`. At `origin/main = 025be5b`:

| Gate | §6 says | Now | Set by |
|---|---|---|---|
| `pnpm --filter @familyshield/api test` | 361 | **381** across 33 files | #162 363, #168 369, #180 381 |
| `qa-probe` | 130 | **141**, incl. **O1–O11** | #180 (*"probe 141/0 … on a spare :3123"*) |
| `e2e` | 69 | 69 | unchanged |
| `check-probe-integrity` | 0 removed or demoted | *"12 added, 0 removed"* at #180 | run it; do not trust a total from here |
| merged-manifest gate | 2 result sets, the #157 assertions | **10 named assertions**, 2 classes (Play 6 / Full 4), four of them `testOnly` | #157, #169 (CAMERA + queries), #174 |
| `flutter test` | 146 | **202** | #161 158, #184 184, #189 202 |
| Android JVM | 267 per flavour | **344 per flavour** | #169 297, #171 303, #174 307, #179 330, #187 344 |
| `check-docs-links` | 132 | **141** checked (139 between #173 and this refresh) | #160 137, #173/#182 139, §8–§15 +2 |

Two environment deltas that bite the re-runs:

- **Migration `0017_parent_mfa_recovery_codes`** is new since §6 was written. A branch-built server on a
  database that stopped at 0016 will 500 on `/mfa/recover`; apply it first
  (`services/api/prisma/migrations/0017_parent_mfa_recovery_codes/migration.sql`).
- **`adb install -t`** is now mandatory for every debug build (#174): without `-t`, adb refuses a
  `testOnly` APK. The hardware scripts were updated (`scripts/hardware/android-signing-tr07.ps1`), which
  is why a stale command from an older log fails at the install step.

## 15. What this refresh is not

- **Not a re-verification.** No gate in §9 was re-run to write it. The commands I ran are
  `node scripts/check-docs-links.mjs` (raw output in the PR), `git log`/`git log --first-parent`/`git
  show` for the shas, times, heads and merge text, `gh pr view`/`gh issue view`/`gh search issues` for
  the review and issue records quoted in §12, and the `grep`/`sed` reads of `routes/auth.ts`,
  `lib/sessions.ts`, `AccessibilityMonitorService.kt`, `EssentialPackages.kt`,
  `check-merged-manifest-gate.mjs`, `MergedManifestLocator.kt`, `PlayMergedManifestTest.kt`,
  `docs/TESTING.md` and `docs/ROADMAP.md` that the "still true at `025be5b`" claims rest on. The shas
  those reads were taken at are `025be5b` (= `origin/main` when this was written).
- **Not a promotion.** All 18 rows are `author-run`, including the three hardware runs (#163, #174,
  #179/#182) and the diagnosis (#185). A review that reads a diff is not a run; a post-merge acceptance
  (#168) is not a run; an issue that tracks a finding is not a fix. **0 tester-verified.**
- **Not a claim that the §12 findings are unfixed forever.** They have issues with repros (#175, #178,
  #183, #188). They are recorded here because the code at `025be5b` still behaves as the reviews said,
  and because the merge messages do not mention either the review or the issue.
- **Not a substitute for a `TR-*` row.** When a verifier runs one of §13's rows, the record belongs in
  [`TEST-REQUESTS.md`](TEST-REQUESTS.md) with raw output, and this file can then cite it.
- **Not the whole day, in either clock.** In UTC this file plus the 2026-10-18 ledger hold
  `603a33d..025be5b`; on the maintainer's +0400 clock the "2026-10-19" day is §3's single merge
  (`4e56410`) plus all 18 above. Anyone counting a day must say which clock — the one thing this file has
  now got wrong twice, and the reason §8 repeats the three readings.

## 16. The third batch — boundary, and why this one is eleven merges

**Written 2026-10-19 18:20 +0400 (14:20Z), same author, same rules.** §9's rows stop at #189
(`025be5b`, 05:43:16Z) because that was `origin/main` when §8 was written. The day did not stop there:

| Reading | Range | Merges |
|---|---|---|
| local (+0400) | 2026-10-19 10:11:22 → **14:40:18** | 11 |
| UTC | 2026-10-19 **06:11:22Z → 10:40:18Z** | 11 |
| `git log --first-parent --format='%h %s' 025be5b..origin/main` | — | **11** |

Every one is a PR merge on `--first-parent`; no direct push, no `merge: main into <branch>` sync at the
top level (§1 records why those are counted separately). **This is the first window in this file where
the local and UTC clocks agree on the date** — §1 and §8 each spend a table explaining why theirs do
not, and the same reading applied here returns 11 in both, because the window sits entirely inside
06:11Z–10:40Z on 2026-10-19.

Two things a reader will otherwise hunt for:

- **The PR numbers skip.** #192 is the **issue** #193 closes; #199 and #202 are **issues** too
  (`gh pr view 199` → `Could not resolve to a PullRequest`). #198 merged *after* #200 despite its lower
  number. Nothing is missing from the table.
- **#190 is this file's own second-half PR** (`2b87c36`) and it gets a row. §9 already said the ledger's
  own PRs are not exempt (#160, #173); the same rule applies to the PR that wrote §8–§15.

## 17. The 11 merges

Sorted by merge time (UTC). Quotations are verbatim from `git log -1 --format=%B <sha>` or the PR body,
as marked with `PR:` when the number is not in the merge message. "Head" is the second parent — the sha
the numbers should belong to.

| PR | Title | Merged as (UTC · local) | Head | Who ran what · exact numbers claimed | Status |
|---|---|---|---|---|---|
| [#190](https://github.com/handfulofluck-lab/osra/pull/190) | docs(qa): ledger for the second half of 2026-10-19, and the four merges that shipped over an open review | `2b87c36` 06:11:22Z · 10:11:22 | `59f24a6` | **Kimi (author, docs).** *"Docs-only; links 0/141. … Nothing was promoted: 18 author-run, 0 tester-verified."* `PR:` *"0 broken link(s) out of 141 checked in 71 Markdown file(s)"*. It is the PR that wrote §8–§15 | author-run |
| [#191](https://github.com/handfulofluck-lab/osra/pull/191) | feat(parent-app): consent status and withdrawal screen (plan 3.7) | `675a118` 06:20:18Z · 10:20:18 | `b315e5f` | **Kimi (author).** *"Evidence at b315e5f (CI 7/7): vitest 382 passed, flutter 218 passed (14 new consent tests + 2 RTL), analyze clean, API untouched otherwise."* Probe and e2e **not run from the branch** and disclosed: *"the API at 127.0.0.1:3000 predates this tree and must not be restarted from a feature branch"*. `PR:` fail-before on the one API field — *"Tests 1 failed \| 18 skipped (19)"* → *"19 passed"* | author-run — the live half not run, disclosed |
| [#193](https://github.com/handfulofluck-lab/osra/pull/193) | fix(android): the block exemption is the agent's own package, not the whole `com.familyshield` namespace (closes #192) | `7e5bc42` 07:42:58Z · 11:42:58 | `646685a` | **Kimi (author).** *"Fail-before reproduced on the old predicate (2 tests red), then 345 tests per flavour green, merged-manifest gate green."* `PR:` `suites=52 tests=345 failures=0 skipped=0` per flavour; manifest gate *"2 result set(s) checked, all assertions ran and passed"*. Hardware row **left open by the PR itself**: *"install a stub com.familyshield.<x> and open it during bedtime … it needs no device admin, so the testing lane can run it"* | author-run — the bypass row the fix is about has never been measured on a phone |
| [#194](https://github.com/handfulofluck-lab/osra/pull/194) | fix(android): PiP and split-screen no longer escape the lock or block overlay (closes #175) | `bf8e1f8` 07:53:29Z · 11:53:29 | `0646e94` | **Kimi (author).** *"Evidence at 0646e94 (CI 7/7 after merging main): 354 tests per flavour; the new MultiWindowCoverageTest fails 5 of 10 against the old active-window-only decision and passes after. Not measured on hardware — the phone's Knox state blocks a clean run."* `PR:` *"53 suites, 354 tests, 0 failures, 0 errors, 0 skipped"* per flavour; the fail-before is *"10 tests completed, 5 failed"* | author-run — and the merge message's `closes #175` did **not** close it: #175 is open, re-stated by Claude at 08:49:09Z (§19) |
| [#195](https://github.com/handfulofluck-lab/osra/pull/195) | fix(api): after an MFA recovery, the password alone cannot open a session (closes #183) | `da2ee94` 08:03:57Z · 12:03:57 | `5c5fc4d` | **Kimi (author).** *"Evidence at 5c5fc4d (CI 7/7 after merging main): vitest 386 passed; fail-before is 'expected false to be true' for mfaEnabled and 'expected 401 to be 200' for verify; probe 143/0 with O12/O13 on a spare :3419; e2e 69/69; flutter 219; probe-integrity 2 added, 0 removed."* `PR:` *"probe integrity: … (check=120 …) -> (check=122 …)"* | author-run — merged 31 m 32 s after a review whose two required changes never landed (§19), and #183 closed anyway |
| [#196](https://github.com/handfulofluck-lab/osra/pull/196) | ci: block merging until another agent has verified the PR head | `a69f955` 08:23:07Z · 12:23:07 | `7e1236d` | **Kimi (author + verifier).** *"Verified by the lead at 7e1236d: workflow checked line by line (label test, signed-comment scan, sha-prefix comparison against the current head, comment-then-label ordering, read-only token), check-workflows 0/0 across 5 files, links 0/142."* The head **is** the verifier's own commit — the self-verification #198 was opened to forbid. Its own `verified-gate` run at that head failed in **0 s with no jobs** (run `39220893201`, 08:10:31Z; the broken YAML #197 diagnosed) | author-run — **self-verification, disclosed**; carries `state:verified` |
| [#197](https://github.com/handfulofluck-lab/osra/pull/197) | fix(ci): `verified-gate.yml` parses again; workflow-lint now really parses YAML | `03161bb` 08:39:09Z · 12:39:09 | `36a37c4` | **Kimi (author).** *"Gates: PyYAML parses both changed workflows; node scripts/check-workflows.mjs --strict 0/0 across 5 files; node scripts/check-docs-links.mjs 0/142."* The merge message names its own red check: *"this PR's own verified-gate check is red for the honest reason — it is my PR and nobody else has verified it, and both verifiers are idle. The gate is NOT yet a required check"* | author-run — verified-gate **red at merge**, disclosed |
| [#200](https://github.com/handfulofluck-lab/osra/pull/200) | fix(hardware): a testOnly/debuggable build is not gate evidence (closes #178) | `fa6f7c5` 09:03:01Z · 13:03:01 | `97fd2f0` | **Kimi (author, per his own comment "produced by a Kimi-run subagent") verified by the lead.** *"this is the first PR where verified-gate actually ran the way it was designed: the label alone was not enough, the signed comment naming the exact head was required, and the check went green only after both existed."* *"8/8 classifier fixtures including verbatim Flip4 output, a deliberately flipped fixture goes red, the three probe outcomes exercised against a fake adb"*; `PR:` every probe outcome pasted — `exit=3` on a test-only build, `#1 … -> FAIL : NOT EVIDENCE (testOnly/debuggable build)`, `run.gateEligible: false` | author-run — the first **green** `verified-gate` before a merge; the signer is the lead and §18.3 explains why that passed |
| [#198](https://github.com/handfulofluck-lab/osra/pull/198) | ci(verified-gate): no self-verification by commit author; signer is the last signature | `2fc03f2` 09:15:28Z · 13:15:28 | `d962756` | **Kimi (merge) + Claude (the branch's one real commit).** *"Verified by the lead at d962756: the branch's only real commit is Claude-authored, its one Kimi commit is a two-parent merge (git log %ae %p), YAML parses, check-workflows 0/0 across 5 files, and this PR's verified-gate check went green only after the label and the signed comment named that head."* `PR:` *"node scripts/check-workflows.mjs --strict: 0 errors, 0 warnings"* | author-run — **the closest call in the batch**: one non-author record at the merged sha, but the signer is also the merger and the authorship rests on a commit email (§18.3). Not promoted |
| [#201](https://github.com/handfulofluck-lab/osra/pull/201) | feat(3.4): the child app reports its installed apps and parents pick from them | `96d0d2c` 09:55:25Z · 13:55:25 | `7c1651a` | **Kimi (author).** *"Evidence at 7c1651a: vitest 395 passed (9 tests fail before the routes exist); probe 151/0 on a spare :3114 with G24-G29, J3e and N6f …; e2e 69/69."* `PR:` *"=== E2E: 71 passed, 0 failed ==="*, *"362 tests / 0 failures / 0 errors / 0 skipped, 54 suites per flavour"*, `flutter` *"+226: All tests passed!"*, integrity *"no assertion removed or demoted (7 added, 0 promoted)"*. **The merge message's e2e total is one run behind its own PR body** (§21). *"verified-gate is red for the honest reason … the fifth such disclosure today"* | author-run — merged 8 m 57 s after a two-change review; one of the two landed (§19) |
| [#203](https://github.com/handfulofluck-lab/osra/pull/203) | feat(3.8): the last five screens onto the design tokens; one severity rule | `01c98a9` 10:40:18Z · 14:40:18 | `b19697a` | **Kimi (author).** *"flutter test 236 passed, analyze clean."* `PR:` *"flutter test → 237 passed (226 before this branch)"* and the raw *"01:35 +237: All tests passed!"* — **the two disagree by one and neither is withdrawn** (§21). Contrast computed for every severity label in both themes: *"worst case 4.70:1 light, 4.97:1 dark"*. One deliberate light-mode change named: *"#4CAF50 (white icon at 2.78:1) to tokens.ok #1B5E20 (7.87:1)"*. *"verified-gate is red for the honest reason (Kimi-authored, both verifiers idle, gate non-binding)."* | author-run — **zero review comments on the PR**, red check disclosed |

**Totals: 11 merges — 0 tester-verified, 11 author-run, 0 with no run at all.** Ten changed a non-Markdown
file (four are CI workflow/script changes: #196, #197, #198, #200) and one is docs-only (#190). Across the
three batches this file now holds **42 merges** (`162a3e4` → `01c98a9`): 13 + 18 + 11, and **all 42 rows are
`author-run`**. The programme's only `tester-verified` row is #125, and it lives in yesterday's ledger's 31
(`VERIFICATION-LEDGER-2026-10-18.md` §2) — it is not one of these rows and this file does not inherit it.

Claims inside these PRs that **no one has run**, named so a reader does not assume otherwise:

- **#193** — the hardware half of the fix it ships: a sideloaded `com.familyshield.unblock` opened during
  bedtime is now blocked. JVM-proven twice over, device-unproven. It needs no device admin, so unlike the
  tamper rows (§20 Block B) this one is **pending, not blocked**.
- **#195** — all three of Claude's open points (§19): the dead-end parent message, the self-inflicted
  lockout, and #183's finding 2 (`incrby` spends the code before the transaction commits). `O12`/`O13`
  cover the login refusal, not the recovery window's failure modes.
- **#194** — PiP. The change judges every visible window and re-raises at most three times per signature;
  whether the overlay sits **above** the pinned window, and whether the video keeps playing, is what
  ADR-0026 leaves to a device — and no device can run it (§20 Block B). Also unrun: the review's ask that
  an exhausted budget surface to the parent as an enforcement gap.
- **#200** — every Phase 1 tamper row on a release-signed APK. The PR's own words: *"the Phase 1 gate is
  now explicitly unproven until those rows are re-measured on the release-signed APK. That was already
  true; it is now visible."* §20 Block B is the consequence table.
- **#191** — the screen against a live API (probe/e2e not run), and the `records` field's probe coverage,
  which the PR names as missing.
- **#201** — the device row (the reporter on a phone: none, no usable admin state) and the picker on a
  real family's app list; `e2e` 71 is one run, at the author's hands.
- **#203** — dark mode by eye on the five migrated screens (widget tests only), and the ~84 px
  search-safety header overflow the run found, which has a fix but no second reader.

## 18. The process gate — `verified-gate`, what it enforces today, and why it is not binding

This is the batch's one structural change: for the first time there is a **machine** check for
`AGENTS.md` §6.5's oldest rule, "the author of a change is never its only verifier". It arrived in four
PRs in **52 minutes** (#196 the gate at 08:23Z, #197 repairing its YAML at 08:39Z, #200 the
build-evidence rule that used it at 09:03Z, #198 closing the self-verification hole at 09:15Z). What
follows separates what it *does* from what it *is not yet*, because the difference is a maintainer action,
not code.

### 18.1 What it enforces, exactly

Three conditions, one trap, and a read-only token. Line references are
`.github/workflows/verified-gate.yml` at `01c98a9`.

| # | Condition | Where | Note |
|---|---|---|---|
| 1 | The PR carries the `state:verified` label | `:52` | Fails with *"Not verified: PR #N has no 'state:verified' label (AGENTS.md §6.5, §10)"* |
| 2 | A PR comment's **last** `— Antigravity`, `— Claude` or `— Kimi Code` signature is the signer, and that comment contains `Verified-sha: <7–40 hex>` which is a prefix of the PR's **current** head | `:71`, `:82` | "Last signature, not any mention" — #198's fix; a comment that quotes another agent's signature no longer counts as that agent's |
| 3 | A `— Kimi Code` signature does **not** count when the PR has ≥1 Kimi-authored **non-merge** commit, matched on `commit.author.email == "kimi@familyshield.local"` | `:62` | A merge of `main` into the branch is bookkeeping and does not count (§6.5 rule 6) |
| trap | Adding (or removing and re-adding) the **label** is what re-runs the job — a comment alone re-runs nothing; any push after verification changes the head and turns the check red until the new head is verified | `:31` | §6.5 rule 4 ("the verified sha is the merged sha") made mechanical |
| limit | `permissions: contents: read` + `pull-requests: read` | `:33-35` | The job cannot remove a label or edit a comment; there is no silent bypass inside it |

### 18.2 It is **not** a required check — measured, not assumed

```bash
gh api repos/handfulofluck-lab/osra/branches/main/protection
# → {"required_pull_request_reviews":{…,"required_approving_review_count":0},
#    "enforce_admins":{"enabled":false}, "required_conversation_resolution":{"enabled":true}, …}
#    There is NO "required_status_checks" member in the response at all.
```

So a red `verified-gate` blocks nothing today, and four merges in this batch say so in their own merge
messages (#196, #197, #201, #203). The check's whole history is 19 runs between 07:36Z and 10:27Z:
**2 successes, 17 failures**, and the two successes are #200's head (`97fd2f0`, 09:01:07Z) and #198's
(`d962756`, 09:05:03Z). Per merge:

| PR | `verified-gate` on the head that landed | Merged |
|---|---|---|
| #190, #191, #193, #194, #195 | **no run** — the workflow first ran at 07:36Z, on #196's branch | 06:11Z–08:03Z |
| #196 | **failure, 0 s, no jobs** (run `39220893201`, 08:10:31Z) — the YAML #197 fixed | 08:23:07Z |
| #197 | failure (Kimi-authored, nobody else verified) | 08:39:09Z |
| #200 | **success** 09:01:07Z | 09:03:01Z |
| #198 | **success** 09:05:03Z | 09:15:28Z |
| #201 | failure 09:46:39Z | 09:55:25Z |
| #203 | failure 10:27:43Z | 10:40:18Z |

**2 of 11 merges had a green gate on the head that landed.** That is the number a reader should carry:
the gate exists, it works, and it was binding on two merges out of eleven.

### 18.3 Who could actually sign — the window's verification records, read as data

- **`Verified-sha:` comments in the repo: a search for the literal string returns six PRs** — #63, #64,
  #65 (2026-10-16/17) and #196, #198, #200 (today). In this window: **three, all signed `— Kimi Code`.**
- **Comments signed `— Antigravity`: zero** on any of the 11 PRs. Of the 11, seven have no comments at all
  or only the lead's; #193, #194, #195 and #201 carry one `— Claude` review each and **none of them
  contains a `Verified-sha:` line** — a review is not a verification record under §6.5 rule 6.
- **Under the rule as it now stands the three signatures split.** #196's is **ignored** (its head
  `7e1236d` is a Kimi non-merge commit). #198's and #200's are **accepted — for the commit email, not for
  authorship**: #198's one real commit is `329687611+handfullofluck-lab@users.noreply.github.com`,
  #200's is `handfullofluck@gmail.com`, and #200's verification comment says the PR *"was produced by a
  Kimi-run subagent"*. The lead also commits under the noreply address in the same window (#196's
  `ea3c439`). One shared account (§11) means the email test cannot separate the agents; the workflow's own
  header says as much (`:19-21`) and this batch is the measurement of it.
- **Two rows are therefore arguable, and neither is promoted here.**
  - **#198** is the closest thing to a non-author verification in the batch: the change is Claude's (per
    the commit and per the merge message), the record is the lead's at the merged head `d962756`, and the
    check was green before the merge. §2's definition is met on its face. It is **not** promoted because
    the same verifier is the merger and the authorship attribution is a single email on an account all
    three agents use — exactly the ambiguity §11 exists for. What would settle it is one comment signed
    `— Claude` or `— Antigravity` with `Verified-sha: d962756`. Nobody has written it.
  - **#200** is the batch's only green-gate merge that a strict reading calls a self-verification: the
    verification comment names the lead, the PR came from a Kimi-run subagent, and the gate passed because
    the commit email was not `kimi@familyshield.local`. It stays `author-run`.

### 18.4 What binding it would cost, given both verifiers' availability

Binding is two maintainer actions, not a code change: make `verified-gate` a **required status check** on
`main`, and turn **"Do not allow bypassing the above settings"** on (`enforce_admins`), because every agent
pushes as a repo admin. #196's merge message records them as *"Binding step for the maintainer"*.

What that would do to **today's** eleven merges, from the tables above:

| Consequence of binding today | Evidence |
|---|---|
| **9 of 11 would not have merged.** Only #198 and #200 had a green check on the landed head | §18.2 |
| **The lead could not sign 9 of 11** — those heads carry a `kimi@familyshield.local` commit (#190, #191, #193, #194, #195, #196, #197, #201, #203); #198 and #200 carry none | `git rev-list --no-merges <merge>^1..<head>`, author email per commit |
| **The wait would be on verifiers who wrote no verification line in this window** — Antigravity: no comment on any of the 11. Claude: four comments (three reviews at 07:32Z, one at 09:46Z) and issue #199 at 08:49Z, none with a `Verified-sha:` line | §18.3, PR comment threads |
| **A security fix would have stalled.** #195 closes a `security/high` account-takeover window (#183) and merged 31 m 32 s after its review; bound, it would have waited for a signature that was not coming | §19 |
| **Every MFA, consent, installed-apps and token change would wait on one person** — the four product PRs in the batch (#191, #195, #201, #203) are all Kimi-authored | §17 |

The decision is not "the gate is wrong"; it is that **the gate has no second signer on this host**. #197's
merge message states the same in its own words: *"I am not binding it while the only active verifier is the
author of most changes: that would stall every merge, including security fixes. Making it required is the
maintainer's decision and needs an availability plan for Claude/Antigravity."* #198's does too: *"I can no
longer verify any PR that carries a Kimi commit, so my own PRs now need Claude or Antigravity."*

**What would make binding safe, in order.** (1) A named verifier who is reachable inside the merge cadence
— the ask per PR is one signed comment with a `Verified-sha:` line, then the label, which is two minutes of
work and is the whole of §6.5 rule 6. (2) The documented override kept real (§6.5's maintainer override,
named in the merge message and recorded in the discussion log) so a security fix is never hostage to a
sleeping verifier. (3) Then bind, and re-measure with the table above as the baseline. Until (1), binding
converts a **disclosed** fact ("merged on the author's run") into a **stalled** programme — worse evidence,
not better.

**What the gate buys even unbound, and this is real:** an unverified merge is now visible in the PR's
checks, and the merge messages name it. #201 and #203 both say *"verified-gate is red for the honest
reason"* in the merge body, which is a sentence that did not exist before 2026-10-19.

## 19. The reviews in this window, and what the tree does not do yet

Claude reviewed four of the eleven (#193, #194, #195 at 07:32Z; #201 at 09:46Z) and collected the open
points as issues #199 (08:49:12Z) and a re-statement on #175 (08:49:09Z). Every merge below happened
**after** the review that named changes, and none of the merge messages mentions the review. Checkable in
one sitting, no phone and no stack:

| PR | Review → merge | What the review required | In the tree at `01c98a9`? | Tracked by |
|---|---|---|---|---|
| #193 | 07:32:28Z → 07:42:58Z (**10 m 30 s**) | *"correct, ready for verification"* plus one ask: a guard test asserting `OWN_PACKAGE == BuildConfig.APPLICATION_ID` so a future `applicationIdSuffix` turns red in CI | **No.** `apps/child-android/app/src/main/java/com/familyshield/agent/enforcement/EssentialPackages.kt:65` is a hard-coded `const val OWN_PACKAGE`, and `grep -rn "APPLICATION_ID" apps/child-android/app/src` returns nothing | [#199](https://github.com/handfulofluck-lab/osra/issues/199) item 4 |
| #194 | 07:32:30Z → 07:53:29Z (**20 m 59 s**) | Merge as the split-screen half; PiP needs a window, not an activity (so #175 stays open); two small items — (1) an exhausted retry budget must surface to the parent as an enforcement gap, (2) recycle every window/root | **(2) yes, (1) no.** `AccessibilityMonitorService.kt:198,219,229` recycle and `:209-210` names the finding; the exhausted budget only logs — `:163-171` is a `Log.w` and nothing reaches the parent | [#175](https://github.com/handfulofluck-lab/osra/issues/175) (open; PiP half), (1) **untracked** |
| #195 | 07:32:25Z → 08:03:57Z (**31 m 32 s**) | *"the design is right, two changes before merge"* — (1) the `mfa_reenroll_required` message is a dead end (it tells the parent to use an unused recovery code, and the recovery deleted them all), (2) design the lockout away: keep unused codes at `/mfa/recover`, delete at `/mfa/verify`, add `Parent.mfaRecoveryStartedAt` | **Neither.** `apps/parent-app/lib/providers/auth_provider.dart:200-201` still says *"Sign in with an unused recovery code to finish setting it up."*; `grep -rn mfaRecoveryStartedAt services/api/src services/api/prisma` → no output | [#199](https://github.com/handfulofluck-lab/osra/issues/199) items 1–3 (item 3: #183's finding 2 is still open even though #183 closed) |
| #201 | 09:46:28Z → 09:55:25Z (**8 m 57 s**) | Two changes: (1) mark essential apps in the picker — `essential` on `LauncherApp`, stored on `DeviceApp`, rendered *"Always allowed (needed for calls and safety)"* and not selectable, because a rule on an exempt app silently does nothing; (2) show the package id under every label, because the label is chosen by whoever built the app | **(2) yes, (1) no.** `apps/parent-app/lib/features/rules/rules_editor_screen.dart:700` renders `subtitle: Text(app.packageId)`; `apps/child-android/app/src/main/java/com/familyshield/agent/apps/InstalledAppsPolicy.kt:11-16` still has only `packageId`, `label`, `isSystem`, `launchable` | **nothing** — (1) has no issue |
| #203 | no review exists | — | — | — |

Reproduce the four headline claims:

```bash
grep -rn "APPLICATION_ID" apps/child-android/app/src                                   # #193: no output
grep -n "unused recovery code" apps/parent-app/lib/providers/auth_provider.dart          # #195: still there
grep -rn "mfaRecoveryStartedAt" services/api/src services/api/prisma                     # #195: no output
sed -n '11,17p' apps/child-android/app/src/main/java/com/familyshield/agent/apps/InstalledAppsPolicy.kt  # #201: no essential
```

**What this section does not say.** It does not say the merges were wrong: #193's fix is correct and its
own fail-before is quoted raw (2 red tests on the old predicate), #194's snapshot model is what the
review asked for and its recycling half landed, #195's design is the one the review approved in principle,
and #201's permission decisions were checked and agreed before the two changes. It says the **record**
reads as if the reviews were answered. **Two of the seven named changes landed and five did not; two of
those five have no issue.** The honest merge line would have been one sentence — *"merged with #199 items
1–2 open; the parent message and the lockout design are next"* — and the next reader would not have to
rebuild this table.

One more, because it is a rule and not a judgement: **three of the eleven merged with no state label at
all** (#194, #197, #201). `AGENTS.md` §10 rule 4 says no label means WIP.

## 20. The re-run list for this window, in risk order

Same rule as §5 and §13: **one live gate at a time, ≥ 60 s apart**; the shared `:3000` rate-limits at
200 req/min and a second concurrent gate aborts with exit 2 (the #114/#129 contract, not a failure).
Nothing in §5 or §13 is withdrawn — this block is additive, and #195 and #193 go **first** because they
are the batch's two security fixes and both merged with their reviews unanswered.

### Block A — the two security fixes (highest risk first)

1. **#195 — MFA recovery, and the window it leaves open** (`da2ee94`). Two things to re-run, and they are
   different in kind: the fix, and the three points the review left open.

   ```bash
   # the fix: recover, then a password-only login must mint nothing
   curl -s -XPOST http://127.0.0.1:3419/v1/auth/mfa/recover -H 'content-type: application/json' \
     -d '{"email":"<acct>","password":"<pw>","code":"XXXX-XXXX-XXXX-XXXX"}'
   curl -s -XPOST http://127.0.0.1:3419/v1/auth/login -H 'content-type: application/json' \
     -d '{"email":"<acct>","password":"<pw>"}'
   #   pass = 401 {"error":"mfa_reenroll_required"}, and NO token / refreshToken / recovery token
   ```

   Then the numbers: vitest **386**, probe **143/0** with `O12`/`O13`, e2e **69/69**, `flutter test` **219**,
   integrity **2 added, 0 removed** — all claimed at `5c5fc4d` on a spare `:3419`. *Apply migration `0017`
   first* (§13's warning still holds). Then, as **evidence for #199, not as a regression hunt**: (a) the
   dead-end message at `auth_provider.dart:200` — what a parent sees after a recovery; (b) `incrby`
   rejecting must not spend the recovery code (today `routes/auth.ts:502` runs the revocation **after**
   the transaction, which is #183's finding 2 and is still open); (c) the lockout path — lose the
   15-minute token before `/mfa/verify` and there is no self-service way back.

2. **#193 — the namespace-prefix bypass, and the hardware row nobody ran** (`7e5bc42`). The JVM half
   reproduces cheaply: restore the old predicate and watch exactly **2** tests go red
   (`RuleRepositoryEssentialExemptionTest`, `EssentialPackagesTest`), then **345 tests per flavour** and
   the merged-manifest gate green. The half that matters is the one the PR left open and that needs **no
   device admin**: build a throwaway APK with `applicationId com.familyshield.unblock` and a launcher
   icon, install it, set bedtime active, open it → the overlay must come up and the logcat line must name
   `com.familyshield.unblock`. Before #193 this was the cheapest real bypass in the tree; a PASS here is
   the only thing that shows it is closed on a device.

### Block B — the gate's own evidence rule, which invalidates earlier PASSes rather than testing a fix

3. **#200 — every Phase 1 tamper PASS we hold is now explicitly not evidence** (`fa6f7c5`). The rule is
   `docs/QA/TESTING-STRATEGY.md` §3b (`:144-173`): **gate-eligible evidence for the Phase 1 tamper rows is
   a release-signed build installed through `scripts/hardware/android-signing-tr07.ps1`**, and the run's
   table must name the build kind. The tooling enforces it before row 1: a `test-only`/`debuggable` build
   is refused with **exit 3 and nothing measured**, or under `-AllowTestBuild` every row is prefixed
   `NOT EVIDENCE (testOnly/debuggable build)` and the JSON carries `gateEligible: false`.

   **So these rows change status, and it is a status change, not a re-run:**

   | Row | Measured on | Now reads |
   |---|---|---|
   | TR-21 rows 1 and 3 (`main@7435592`, `main@4adc601`) | Full/Play **debug** APKs | **NOT EVIDENCE** — row 1's `DELETE_FAILED_DEVICE_POLICY_MANAGER` was a *test* admin's; the release admin is the thing the gate is about |
   | TR-22 rows 1 and 3 (`main@40f4f61`, 474 s measurement) | Full **debug** APK (`testOnly` since #170) | **NOT EVIDENCE** — the behaviour is measured, the protection is not |
   | TR-15 (the ten-bypass Phase 1 gate) | never measured | **NOT EVIDENCE, still** — it has no run at all |
   | TR-10 (1.1/1.2 tamper: `adb uninstall` must fail, admin-reactivation alerts, 3.3 s measurement) | Play **debug** build | **NOT EVIDENCE** — same rows as TR-21, same reason: a `testOnly` admin is removable by `dpm` and replaceable by `adb install -r` |
   | TR-23 (21.2 s pairing proxy) | Full **debug** | **proxy, not gate evidence** (§3b: *"a number taken on a debug install is a proxy for the release experience and cannot open a gate"*) |
   | TR-16, TR-17, TR-14, TR-13, TR-18, TR-19's S1/S1b | debug builds (TR-18: a release-variant APK) | **unaffected** — §3b:160-162 keeps safety and behaviour rows eligible (S-rows explicitly), provided the record names the build kind. TR-18 already measured the release variant, which is why its FGS/cleartext assertions are the one set here that §3b's first sentence does not disqualify — it did not measure a tamper row |

   **And there is no measurement path on this host, twice over** (§11): the release build is HTTPS-only
   (`cleartextTrafficPermitted` false, TR-18) and there is no HTTPS API endpoint here; the Flip4 cannot
   activate a device admin at all since its Knox row went stale (#181, #185). So the tamper rows are
   **blocked**, not pending — a planner who reads "open" will schedule them and lose a day. What *can* be
   run today, and costs nothing:

   ```bash
   pwsh -NoProfile -File scripts/hardware/classify-build.ps1 -SelfTest      # expect 8/8, exit 0
   # on the debug APK, with a fake adb or a real device: the probe must REFUSE
   ./scripts/hardware/android-bypass-probe.ps1 -Serial <serial> -Port <port> -StateFile <state.json> -CheckBuild
   #   expect: REFUSED: … is a test-only build (flags=[… TEST_ONLY]) … exit=3
   ```

4. **#194 — PiP, and the one item that needs no device** (`bf8e1f8`). Reproduce the fail-before (**5 of
   10** in `MultiWindowCoverageTest` against the active-window-only decision) and **354 tests per
   flavour**. Then the two device questions ADR-0026 leaves open are **blocked** (§11); the free one is
   the review's item (1): read `AccessibilityMonitorService.kt:163-171` and confirm that an exhausted
   retry budget produces a `Log.w` and nothing the parent can see — which is what #175's re-statement at
   08:49:09Z says is still missing.

### Block C — the API surfaces and the clients

5. **#191 — the consent `records` field** (`675a118`). vitest **382** reproduces; then the live half the
   PR did not run, on a branch-built server: `GET /v1/family/children/:id/consent` must return `records`
   including revoked and expired rows, and the parent screen's five states must derive from it. The probe
   gap the PR names (`J3` checks enforcement, not `records`) is the cheap fix here.
6. **#201 — installed apps** (`96d0d2c`). vitest **395** (9 fail before the routes exist), probe **151/0**
   with `G24–G29`, `J3e`, `N6f` on a spare port, e2e **71/71**, Android **362 tests / 54 suites per
   flavour**, `flutter` **226**. Two decisions to test rather than re-read: the read is gated on `rules`,
   not `devices` (a co-parent admitted only for `alerts` must get `403` — `N6f` pins it), and the write is
   `requireOwnDevice` (a device reporting **another** device's inventory must be refused). The device row
   is blocked; the picker is widget-tested.
7. **#203 — the tokens, and one number to settle** (`01c98a9`). `flutter test` — **237** in the PR body,
   **236** in the merge message; run it and record which. Then the part no test covers: dark mode by eye
   at 320×568 on the five migrated screens, and the ~84 px search-safety header overflow the run found
   (fixed; no second reader).

### Block D — docs and CI workflows (a diff read, §6.5's proportional check)

8. **#190, #196, #197, #198, #200's docs** — every cited `file:line` must say what the text claims. While
   in there, the two questions §18.3 leaves open are answerable with one comment each: a `Verified-sha:
   d962756` signed by a second agent turns #198 into this file's **first** `tester-verified` row (the
   programme's second, after #125), or a decision that it stays `author-run`; and `TEST-REQUESTS.md`'s
   TR-21/TR-22/TR-23 status cells still read **PASS** for rows §20 Block B now calls **NOT EVIDENCE** — a
   superseding note is owed there, and this ledger is not the file that owns them.

## 21. The counts moved again — use these at `01c98a9`

§6's numbers were true at `4e56410`, §14's at `025be5b`. At `origin/main = 01c98a9`:

| Gate | §6 | §14 | Now | Set by |
|---|---|---|---|---|
| `pnpm --filter @familyshield/api test` | 361 | 381 | **395** across 34 files | #162 363, #168 369, #180 381, #191 382, #195 386, #201 395 |
| `qa-probe` | 130 | 141 | **151** (new since §6: `O1`–`O13`, `G24`–`G29`, `J3e`, `N6f`) | #180 141, #195 143, #201 151 |
| `e2e` | 69 | 69 | **71** | #201 (*"E2E: 71 passed, 0 failed"*) — **note:** #201's merge message still says `69/69`, one run behind its own PR body |
| `check-probe-integrity` | 0 removed | *"12 added, 0 removed"* | `check=129` at #201 (*"7 added, 0 promoted"*) | run it; do not trust a total from here |
| merged-manifest gate | 2 result sets | 10 named assertions | **unchanged since #174** — Play 6 / Full 4, four `testOnly` | #193 reports the same 10 green |
| `flutter test` | 146 | 202 | **237** per the PR body, **236** per the merge message — unresolved | #161 158, #184 184, #191 218, #189 202, #195 219, #201 226, #203 236/237 |
| Android JVM | 267 / flavour | 344 / flavour | **362 tests, 54 suites per flavour** | #193 345, #194 354, #201 362 |
| `check-docs-links` | 132 | 141 | **144** (142 before this refresh) | #196/#197/#200 142; §16–§22 and the board line +2 |
| `verified-gate` | — | — | 19 runs, **2 green**, **0 required** | §18.2 |

Two environment deltas that bite the re-runs: **migration `0017_parent_mfa_recovery_codes`** must be
applied before any MFA row (§13), and **`adb install -t`** is mandatory for every debug build since #174.
A third joins them with #200: `scripts/hardware/android-bypass-probe.ps1` now **refuses to measure
anything** on a debug build unless `-AllowTestBuild` is passed, and its `bypass-probe.json` shape changed
from a top-level array to `{ run, results }` — an external consumer that reads the old shape will break,
and no in-repo consumer reads it.

## 22. What this refresh is not

- **Not a re-verification.** No gate in §17 was re-run to write it. The commands I ran are
  `node scripts/check-docs-links.mjs` (raw output in the PR), `git log`/`git show`/`git rev-list` for the
  shas, times, heads, parents and author emails, `gh pr view`/`gh issue view`/`gh api` for the PR bodies,
  comment threads, check runs and branch protection, and the `grep`/`sed` reads of
  `verified-gate.yml`, `auth_provider.dart`, `EssentialPackages.kt`, `InstalledAppsPolicy.kt`,
  `rules_editor_screen.dart`, `AccessibilityMonitorService.kt`, `TESTING-STRATEGY.md` §3b and
  `check-merged-manifest-gate.mjs` that the "still true at `01c98a9`" claims rest on.
- **Not a promotion.** All 11 rows are `author-run`, including #198 (the batch's only non-author record)
  and #200 (its only green-gate merge). §18.3 states exactly what would change either verdict: one
  comment. **0 tester-verified in this window.**
- **Not a verdict on the process gate.** §18 records what it enforces (`:52`, `:62`, `:71`, `:82`), that it
  is not required (`gh api … /protection` has no `required_status_checks` member), what binding would have
  cost today (9 of 11 merges, and #195's security fix), and what has to exist first. The decision is the
  maintainer's, per §6.5's own override clause.
- **Not a claim that §19's findings are permanent.** Three of the five unlanded review points are tracked
  by [#199](https://github.com/handfulofluck-lab/osra/issues/199) (its items 1, 2 and 4) and the PiP half
  by [#175](https://github.com/handfulofluck-lab/osra/issues/175); **two are tracked by nothing** — #194's
  exhausted-budget-to-parent item and #201's `essential` flag — and that, not the review's lateness, is
  the finding.
- **Not a substitute for a `TR-*` row.** When a verifier runs one of §20's rows, the record belongs in
  [`TEST-REQUESTS.md`](TEST-REQUESTS.md) with raw output, and this file can then cite it.
- **Not the whole day, in either clock.** This file now holds `162a3e4..01c98a9` in three batches
  (§3 13, §9 18, §17 11); with the 2026-10-18 ledger that is `603a33d..01c98a9`, **73 merges** (31 + 42),
  which supersedes §7's "62" and §15's "not the whole day" arithmetic. The one thing this file has got
  wrong twice is counting a "day" without saying which clock — §16 says it for this batch, and the answer
  is that 06:11Z–10:40Z is the same date in both.
