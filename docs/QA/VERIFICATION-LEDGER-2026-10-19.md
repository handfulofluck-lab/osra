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
| [#143](https://github.com/handfulofluck-lab/osra/pull/143) | docs(qa): verification ledger for the 2026-10-18 merges | `162a3e4` 16:55:43Z | `ff9c061` | **Kimi (author, docs).** links *"0 broken link(s) out of 127 checked in 66 Markdown file(s)"*, `EXIT=0`. **Non-author record:** Claude's diff read at **16:46:16Z**, on this head, closed *"With those three changes, I approve the docs from the architecture side"* — and **none of the three is in the merged tree** (§4.3, item 1) | author-run — the one non-author read ended **conditional and unfulfilled** |
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
neither is upgraded here.**

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

## 5. What a verifier should re-run first — in risk order

Ordered by the cost of being wrong. The first block is the API authorization and session-state work, the
second the Android manifest and location work, the third the remaining API correctness and the gates'
own integrity, the fourth UI, and docs last. **One live gate at a time, ≥ 60 s apart** — the shared API
rate-limits at 200 req/min and the later gate aborts with exit 2 (that is the #114/#129 contract, not a
failure).

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
   `/v1/devices/:id/commands/history` (needs the lease; §6.7).

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
  `TESTING-STRATEGY.md` and `TEST-REQUESTS.md` that back the "paid" verdicts in §4.
- **Not a status upgrade.** All 13 rows are `author-run` because that is what the records say. The two
  non-author records in the batch are quoted with their timestamps so a reader can see what they were:
  a conditional approval whose conditions did not land (#143) and an acceptance that arrived after the
  merge (#154).
- **Not a substitute for a `TR-*` row.** When a verifier does re-run a row above, the record belongs in
  [`TEST-REQUESTS.md`](TEST-REQUESTS.md) as its own request with raw output, and this file can then cite
  it — that is the file working, not this one going stale.
- **Not the last word on the 2026-10-18 UTC day.** Yesterday's ledger holds merges 1–31 and this one
  holds 32–44; the pair is the day, and neither alone is.
