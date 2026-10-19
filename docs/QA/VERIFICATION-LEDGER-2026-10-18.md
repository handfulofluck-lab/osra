# Verification ledger — the 2026-10-18 merges

**Written 2026-10-18 16:30Z by Kimi Code (development lead).** Covers every pull request merged into
`main` on **2026-10-18 UTC**: **31 merges**, `603a33d` (07:13Z) → `f2437a9` (16:19Z), all of them merge
commits, no direct push. Source of each entry, in this order: the merge commit message
(`git log -1 --format=%B <sha>`), the PR body at its merged head, and any comment on the PR. Nothing
below is a re-run I performed — except `node scripts/check-docs-links.mjs`, whose raw output is in this
change's pull request. It is a ledger of **what is on record**, not a new verification.

> **Later batch:** the merges after `f2437a9` are in
> [`VERIFICATION-LEDGER-2026-10-19.md`](VERIFICATION-LEDGER-2026-10-19.md) (13 merges, `162a3e4` →
> `4e56410`). This file is not edited by that one; the two together are the 2026-10-18 UTC day, 44 merges.

> One boundary case, so the count cannot be argued with: `f25ed54` (#86, ADR-0017/0018/0019) carries the
> commit date `2026-10-18 00:05:35 +0400`, which is `2026-10-17T20:05:35Z`. It belongs to the 2026-10-17
> batch and is **not** one of the 31 below. `git log --first-parent --since=2026-10-18T00:00:00+0400`
> therefore returns 32 merge commits, not 31.

Why the day needed one: the lead merged this batch while Claude and Antigravity were idle, so under the
maintainer's standing instruction most of it is recorded as an *author run* (`AGENTS.md` §6.5). Those
numbers are the author's claim. They are valuable — they include fail-before runs that would have caught
the bug if the fix were absent — but they are not the independent verification §6.5(2) asks for, and one
merge (#93) landed three minutes after a changes-requested review whose findings are still open. The
debt is real and this file makes it measurable.

## 0. Amendments (2026-10-19) — the day's record is not rewritten

Claude's diff read of [#143](https://github.com/handfulofluck-lab/osra/pull/143) at 16:46:16Z approved
these two ledgers **conditionally**; #143 merged at 16:55:43Z with none of the three conditions in it
(the successor ledger's §4.3, item 1). Two of the three are about *this* file. A dated amendment is the
honest repair: the rows, totals and debts below are exactly what was written on 2026-10-18, and the
notes here say what has changed since. **No gate was re-run to write them** — the new evidence is the
`file:line` re-read at `1733d83` and the PR/issue records named in each line.

| Claude's condition (#143 review, 16:46:16Z) | Amended 2026-10-19 | Where in this file |
|---|---|---|
| **1a.** the `#131` row must read *known incomplete: #132* | the Status cell now carries `author-run, known incomplete: #132`, and says that #132 was fixed the same day by [#155](https://github.com/handfulofluck-lab/osra/pull/155) (`4e56410`, 20:00:18Z; issue [#132](https://github.com/handfulofluck-lab/osra/issues/132) closed 20:00:20Z) | §2, row #131 |
| **1b.** `#111` fixed the probe only — `#117` was still live | §3 gains item 8 as the eighth debt, marked fixed by [#156](https://github.com/handfulofluck-lab/osra/pull/156) (`0d0418c`, 19:40:02Z; issue [#117](https://github.com/handfulofluck-lab/osra/issues/117) closed 19:40:04Z) | §3, item 8 |
| **2.** the app PIN is in clear text in `docs/QA/TEST-REQUESTS.md` | **closed.** Redacted by [#164](https://github.com/handfulofluck-lab/osra/pull/164) (`e202c9e`, 2026-10-18 21:47:25Z) in the 2026-10-18 13:05Z message, now [`TEST-REQUESTS.md:22`](TEST-REQUESTS.md). #164 removed the digits and wrote prose instead — "the app PIN (held outside this repo)" — rather than Claude's suggested `<app-PIN>` placeholder; the point (no credential in the record) is met either way, and the hardware probe now requires `-Pin` with no default (`docs/TESTING.md:356-360`). `grep -rnE 'app PIN [0-9]{4}' docs scripts` over this tree at `1733d83` returns nothing — the pattern, not the digits, so this file does not undo the redaction. Rotating the physical PIN is a separate half and stays with the maintainer — issue [#151](https://github.com/handfulofluck-lab/osra/issues/151) is still open for it | `TEST-REQUESTS.md` |
| **3.** re-run item 8 (#131) omits the while-in-use-only case from #132 | §4 item 8 now carries that case with the exact commands, so the re-run cannot pass on the boot path alone | §4, item 8 |

Both ledgers' re-run lists carry the case (§4 item 8 here, Block B item 5 in the successor); the
disposition of all three conditions, with PR numbers, is tabulated in the successor ledger's §4.4.

## 1. How to read a row

| Status | Means | What it does **not** mean |
|---|---|---|
| **tester-verified** | An agent other than the author produced a record **against the tree that merged**: it re-ran the gates, or for a docs-only change it read the diff line by line and confirmed every cited `file:line` | That every claim in the PR was tested — only the ones the record names |
| **author-run** | The only numbers on record are the author's (or the lead's, acting as author/merger). They may be complete, honest and fail-before-backed; they are still one party's word | That nobody else *could* run it — only that nobody else did |
| **unverified** | No run is on record, or the run happened against a different tree than the one that landed (a pre-rebase head, an older `main`, a hardware row nobody ran) | That the change is wrong — it means the evidence does not exist yet |

"Gates" are the ones `AGENTS.md` §3 names: the API `vitest` suite, `qa-probe.mjs` (adversarial, live
stack), `e2e.mjs` (happy path, live stack), the client suites (Flutter / Gradle both flavours / `dotnet`),
and `check-docs-links.mjs` for Markdown. A number written `probe 120/0` is the run's own summary line
(`120 passed · 0 failed`). `integrity 94→99` is `node scripts/check-probe-integrity.mjs --base origin/main`
(check counts before → after, and how many assertions were added or removed).

## 2. The 31 merges

Sorted by merge time (UTC). "Head" is the PR head at merge — the sha the numbers belong to.

| PR | Title | Merged as (time) | Head | Who ran what · exact numbers claimed | Status |
|---|---|---|---|---|---|
| [#93](https://github.com/handfulofluck-lab/osra/pull/93) | feat(api): the digest is due at the family's local hour (ADR-0017, plan 2.2) | `603a33d` 07:13Z | `733e2fd` | **Kimi (author).** vitest **28 files / 309 tests**, 0 failed · `tsc --noEmit` exit 0 · migrate `0014` applied · links **0/121** · real-Postgres claim run: first pass `attempted 2, sent 2`, second `0, 0` | author-run — **and a changes-requested review 3 minutes before the merge (§3, item 1)** |
| [#94](https://github.com/handfulofluck-lab/osra/pull/94) | fix(android): check the call-log/SMS permission before querying, not only after the throw (#91) | `9c6d385` 07:13Z | `67f6c8f` | **Kimi (author).** `testPlayDebugUnitTest` and `testFullDebugUnitTest`: **suites=37 tests=241 failures=0** each · hardware row (logcat has no `SecurityException`) **not run** | author-run |
| [#95](https://github.com/handfulofluck-lab/osra/pull/95) | fix(android): the Play build must not ask for notification access it cannot use (ADR-0016 §4) | `fd9ad2e` 07:17Z | `1db8bea` | **Kimi (author).** play **37 suites / 242 tests / 0 failures**; full 241/0 before the new case, both green after · CI 7/7 | author-run |
| [#97](https://github.com/handfulofluck-lab/osra/pull/97) | docs: mark COLLABORATION-ROADMAP superseded | `761a29a` 07:22Z | `a6c7eb4` | **Kimi (author, docs).** links **0 broken / 121 checked in 62 files** · CI green | author-run |
| [#96](https://github.com/handfulofluck-lab/osra/pull/96) | docs(adr): 0020 family timezone source, 0021 Play policy review | `8b1e477` 07:44Z | `df59c48` | **Claude (author, docs); Kimi reviewed the diff at 07:32Z** and accepted with conditions (B1–B3, the conditional fill, three named tests) · links **0/123** | author-run — the lead's read is the only non-author record, and it closed with conditions carried to #98/#101 |
| [#84](https://github.com/handfulofluck-lab/osra/pull/84) | docs(process): roles re-cut, 15/30-minute board cadence, roadmap and documentation rules | `61cf159` 07:57Z | `1224768` | **Claude (author); Antigravity signed off at 06:49Z on `29f78d8`** — cadence 15/30 in both files, links **0/121 in 62 files**. The branch was then rebased twice and its head moved to `1224768`; **no record exists for that head** | author-run for the landed tree — §6.5(4): the verified sha is not the merged sha |
| [#98](https://github.com/handfulofluck-lab/osra/pull/98) | docs(adr): amend ADR-0021 (dialer intents in the Play queries) and ADR-0020 (named tests) | `7ab2a3e` 08:09Z | `12d29a4` | **Claude (author, docs).** links **0/123** · CI green · answers the lead's B1–B3 from #96 | author-run |
| [#100](https://github.com/handfulofluck-lab/osra/pull/100) | fix(android): Play declares no call-log/SMS permissions and no QUERY_ALL_PACKAGES, dialer queries kept (ADR-0021) | `b1aeae6` 08:21Z | `4a177a6` | **Kimi (author).** play and full: **37 suites / 242 tests / 0 failures**, `BUILD SUCCESSFUL in 4m 38s` · `aapt2 dump permissions` on the built APKs: **explicitly not done** in the PR | author-run |
| [#101](https://github.com/handfulofluck-lab/osra/pull/101) | feat(api): Family.timezoneSource and the device fill, never over a parent's choice (ADR-0020) | `9846456` 08:30Z | `219d326` | **Kimi (author).** vitest **29 files / 313 tests** · `tsc` exit 0 · migrate `0015` applied | author-run — a medium defect was found in it **after** the merge by Claude's review and fixed in #105 |
| [#102](https://github.com/handfulofluck-lab/osra/pull/102) | feat(android): the Play build says what it cannot capture (ADR-0021 B3) | `7ac4ffb` 08:42Z | `f5bd0de` | **Kimi (author).** play **37 suites / 244 tests / 0 failures**, `BUILD SUCCESSFUL in 2m 27s` | author-run |
| [#103](https://github.com/handfulofluck-lab/osra/pull/103) | docs(roadmap): move the rows today's merges changed (AGENTS §12) | `e0a4a15` 08:46Z | `7356c05` | **Kimi (author, docs).** links **0/123 in 64 files** | author-run |
| [#104](https://github.com/handfulofluck-lab/osra/pull/104) | docs(adr): ADR-0020 correction — the device fill is guarded by timezoneSource = 'default' | `73829ba` 08:54Z | `4774c28` | **Claude (author, docs).** links clean · CI green. Corrects the wording that produced #101's defect | author-run — no non-author read on record |
| [#105](https://github.com/handfulofluck-lab/osra/pull/105) | fix(api): the device fill is guarded by timezoneSource = 'default' (ADR-0020 decision 4) | `868eb0c` 09:07Z | `9eb47c1` | **Kimi (author).** vitest **313 passed** · `tsc` clean | author-run |
| [#106](https://github.com/handfulofluck-lab/osra/pull/106) | refactor(android): call/SMS capture behind a CommsCapture interface, CommsLogger moves to full (ADR-0021) | `2812cb5` 09:30Z | `e4a1983` | **Kimi (author).** play and full: **37 suites / 246 tests / 0 failures**, both APKs assemble, `BUILD SUCCESSFUL in 5m 54s` | author-run |
| [#107](https://github.com/handfulofluck-lab/osra/pull/107) | feat(parent-app): the digest timezone is a setting, not a hidden default (ADR-0020) | `c6603c8` 10:08Z | `8d3b688` | **Kimi (author).** `flutter test` **+104: All tests passed** · `flutter analyze` no issues · links 0/123 | author-run |
| [#109](https://github.com/handfulofluck-lab/osra/pull/109) | fix(parent-app): the timezone dropdown always includes the family's real zone (closes #108) | `b1ef0f4` 10:37Z | `d8e22a4` | **Kimi (author).** `flutter test` **+105: All tests passed** · analyze clean | author-run |
| [#111](https://github.com/handfulofluck-lab/osra/pull/111) | test(qa-probe): F8 waits for the second boundary and asserts the fresh token works (closes #110) | `0d51356` 11:31Z | `0078039` | **Kimi (author).** `check-probe-integrity`: **check=88 on both sides, 0 removed** · three probe runs on `main@b1ef0f4`: **109/0**, **109/0**, and one **75 passed / 27 failed** that the author attributes to **66 × 429** in the API log (`grep -c '"statusCode":429'`), not to the probe | author-run |
| [#113](https://github.com/handfulofluck-lab/osra/pull/113) | docs(roadmap): Phase 1/2 rows say what is true after the #76–#90 merges (WO-05) | `6265f7f` 11:31Z | `66df2b4` | **Kimi (author, docs).** links **0/123 in 64 files**, exit 0 · CI 7/7 | author-run (lead's own diff read; §12.1 catch-up for four earlier PRs) |
| [#116](https://github.com/handfulofluck-lab/osra/pull/116) | feat(parent-app): command delivery status (plan 3.6) | `530fa0a` 12:15Z | `6f360f8` | **Kimi (author).** `flutter analyze` clean · `flutter test` **+112: All tests passed** (110 before; 7 new in `command_history_test.dart`) · live GET-only read: `history 200 items 1`, keys as expected | author-run — WO-03's tester record is still owed (the board says so) |
| [#115](https://github.com/handfulofluck-lab/osra/pull/115) | docs(qa): the queue says what is true after #79 and #113 (WO-04/WO-05 delivered) | `d754157` 12:26Z | `713e2b1` | **Kimi (author, docs, subagent draft).** links **0/123 in 64 files** · lead read the diff line by line at `713e2b1` | author-run |
| [#124](https://github.com/handfulofluck-lab/osra/pull/124) | fix(api): silence watch matches online; device telemetry self-scoped; push-token sanitized (#121, #122, #123) | `4c41a07` 12:32Z | `cd77260` | **Kimi (author).** vitest **29 files / 318 tests** · integrity **88→88** · fail-before with the source stashed: **7 failed / 17 passed** · **no probe/e2e on the branch; no probe check added** for any of the three findings | author-run |
| [#114](https://github.com/handfulofluck-lab/osra/pull/114) | fix(qa-probe): abort a 429 burst instead of recording phantom failures (#112) | `82edd5e` 12:45Z | `e21e011` | **Kimi (author).** vitest **30 files / 315 tests** · integrity **88→88** · new test fails on `origin/main`'s probe (**2 failed**) · live burst: three concurrent runs, **exit 2 2 2**, **2 + 2 + 2 = 6 × 429**, API log `Rate limit exceeded` 33 → 39 · clean run **109 passed · 0 failed · rate limit 0 × 429** · `e2e` **68/0** | author-run |
| [#125](https://github.com/handfulofluck-lab/osra/pull/125) | fix(api): authorize location pings and scope device reads to the own child | `7435592` 13:00Z | `c3afda6` | **Kimi (author)** — vitest **335 passed** at the merged head per the merge message (the PR body carried **328** at an earlier head) · probe G13–G18 **115 passed · 0 failed** · e2e **69/69** · integrity **88→94, 7 added**. **Antigravity re-ran and signed off at 13:00:34Z** on `c3afda6`: vitest **335/335**, probe **115/0**, e2e **69/69**, integrity 0 removed, links **0/123** | **tester-verified** (Antigravity, at the merged head) — **but the sign-off is timestamped 23 s after the merge commit**, so the merge message does not cite it |
| [#127](https://github.com/handfulofluck-lab/osra/pull/127) | docs(qa): TR-21 hardware results + the two traps that cost the run | `53d1c93` 14:14Z | `6c6c987` | **Kimi (author, hardware run on the Flip4).** row 1 `DELETE_FAILED_DEVICE_POLICY_MANAGER` → **PASS** · row 3 no pid after 121 s → **FAIL** · **S1 and S1b NOT MEASURED** (secure keyguard, PIN ≠ app PIN) · `pause` surrogate dialer focus **2.2 / 6.2 / 11.2 s** on both flavours → PASS · links **0/123** | author-run (hardware rows are the author's per §6.5; S1/S1b are **unverified**) |
| [#130](https://github.com/handfulofluck-lab/osra/pull/130) | fix(api): make the WebSocket handshake ticket-only (#120) | `7ded1ec` 14:24Z | `b8fdeab` | **Kimi (author).** vitest **31 files / 338** · fail-before on `origin/main`'s gateway: **3 failed \| 3 passed**, `404 !== 401` · probe on a branch instance `127.0.0.1:3100`: **120 passed · 0 failed** (L6, L7, L7b, L8, L9) · e2e **69/69** · integrity **94→99, 5 added** | author-run |
| [#129](https://github.com/handfulofluck-lab/osra/pull/129) | fix(e2e): a 429 burst aborts with exit 2, and a missing /me envelope is a recorded failure | `2e1efbd` 14:35Z | `8071bca` | **Kimi (author).** vitest **32 files / 339** in the PR (**342** in the merge message) · fail-before against `origin/main`'s `e2e.mjs`: **4/4 failed, exit 3221226505** · integrity **94→94** · live: probe **exit 2 (1 × 429)**, e2e **exit 2 (1 × 429)**, **0 FAIL lines**, then clean e2e **69/69** after 60 s | author-run |
| [#131](https://github.com/handfulofluck-lab/osra/pull/131) | fix(android): guard the boot location FGS before the grant (closes #128) | `265124f` 14:45Z | `89ea651` | **Kimi (author).** fail-before: `BootStartPolicyTest` **4 tests, 1 failed** at `:25` · after: both flavours **tests=251 failures=0 errors=0** · both APKs built · CI 7/7 at `51f0e87` (child-android 6m10s) · **reboot hardware row not run** (secure keyguard) | author-run, **known incomplete: [#132](https://github.com/handfulofluck-lab/osra/issues/132)** — the boot path was guarded; `AccessibilityMonitorService` and `CommandDispatcher.locate_now` still started `LocationService` without the background grant, so the same crash class stayed live. **Amended 2026-10-19:** #132 is fixed by [#155](https://github.com/handfulofluck-lab/osra/pull/155) (`4e56410`, 20:00:18Z) — the three start sites that can run in the background now share `LocationStartPolicy`; #155 is author-run too, and its hardware path had not been run when it merged |
| [#139](https://github.com/handfulofluck-lab/osra/pull/139) | fix(api): close audit findings 3–5 — nonce fail-closed, MFA re-enrol re-auth, family-move revocation | `ca2d86b` 15:20Z | `553538c` | **Kimi (author).** fail-before: **4 failed \| 37 passed (41)** · vitest **32 files / 346** · integrity **99→99** · probe **120 passed · 0 failed** and e2e **68/0** — **on the live `:3000`, which runs `main@265124f`, i.e. not this branch's code** | author-run — and the live-gate half does not evidence the diff |
| [#140](https://github.com/handfulofluck-lab/osra/pull/140) | fix(desktop): per-install parent PIN (no 0000 default) + validated HTTPS upstreams | `90e0b76` 15:32Z | `57d213c` | **Kimi (author).** `dotnet test` **225 passed / 0 failed** (baseline `main@265124f`: 188) · fail-before: TLS **2 failed / 6 passed**, PIN **22 failed / 27 passed** · merge message records the lead re-running 225/225 on the merged tree · **no live pairing/TLS handshake; no desktop session** | author-run (the manual desktop row is **unverified**) |
| [#141](https://github.com/handfulofluck-lab/osra/pull/141) | fix: gate device register and pair on the devices permission (#138) | `f5143c6` 16:01Z | `bdcff51` | **Kimi (author).** vitest **32 files / 349 tests** · fail-before against `origin/main`'s handlers: **3 failed \| 36 passed (39)** · integrity **99→102, 3 added** · probe **123 passed · 0 failed** on a branch server `127.0.0.1:3100` (N6b, N6c, setup secret check) · e2e **69/69** on the same instance, 65 s later | author-run |
| [#142](https://github.com/handfulofluck-lab/osra/pull/142) | feat(parent-app): daily usage trend and browsing history (roadmap 3.5) | `f2437a9` 16:19Z | `1a4e4f0` | **Kimi (author).** `flutter test` **126 passed** (112 baseline + 14 new) · `flutter analyze` clean (39.4 s) · re-run on the merged tree in the merge message: 126 | author-run |

**Totals: 31 merges — 1 tester-verified (#125, post-merge), 30 author-run, 0 PRs with no run at all.**
Inside those author-run PRs, these named claims have **no run by anyone**: the hardware/manual rows of
#94, #100 (item 4), #131, #140, and TR-21's S1/S1b.

## 3. The debts this table exposes, with evidence

1. **#93 merged over a changes-requested review, and two of its findings are still open on `main`.**
   Claude's review (posted 07:10:08Z; its own header says "07:25Z" — the two clocks disagree, and the
   GitHub timestamp is the one that matters here) asked for F1 (a thrown send loses the period), F2
   (permanent refusals retry every 15 minutes) and F3 (the old UTC contract is still documented); the
   merge landed at 07:13:01Z, under three minutes later. Read today at `f2437a9`:
   - F1 still open — `services/api/src/jobs/digestScheduler.ts:119-120`: the `catch` around
     `sendFamilyDigest` logs and leaves the `DigestSend` claim in place, so every later tick hits
     `P2002` and the family gets no digest that period. The refusal branch at `:113-117` does delete it;
     the two failure paths still disagree.
   - F3 still open — `services/api/.env.example:19` still says `DIGEST_HOUR_UTC=18` and
     `docs/TESTING.md:66` still presents it as the switch, although `digestSchedule.ts:108` now reads it
     as a **local** hour (the silent meaning change the review named).
   - F2 was not implemented either (no `retryable` distinction in the code).
   This is the one row where "author-run" understates the problem: verification happened, it was
   negative, and the merge went ahead. A verifier should treat F1 as a live correctness bug.
2. **#139's live gates ran against the pre-merge tree.** The probe `120/0` and e2e `68/0` executed against
   the shared `:3000` (`main@265124f`); the branch's own changes — `requireFamily`'s new epoch check and
   `Parent.familyId` scoping — were never exercised live. The PR says so itself ("Honest limit"). The
   unit suite is the only evidence for the central auth path changed that day.
3. **#124 added no probe check and ran no live gate.** Three security findings (#121–#123) are covered by
   vitest only; `qa-probe.mjs` was held by a sibling lane and the follow-up it promised has not landed.
   Read at `f2437a9`: the probe has no `device_silent` firing check, no device-A→device-B telemetry or
   activity `403` check, and no secret scan of the `/push-token` response — the only secret check
   (`qa-probe.mjs:204`) covers `/register`, which is #141's route, not #123's.
4. **#84's sign-off does not belong to the tree that merged.** Antigravity verified `29f78d8` at 06:49Z;
   the branch was rebased twice and merged at `1224768`. The diff between them is small, but "small" is
   the judgement a verifier is there to make.
5. **#125's verification postdates its merge by 23 seconds.** The record is good and at the merged head —
   but a merge message written before the sign-off existed cannot cite it, which is why the merge message
   says "Antigravity idle". §6.5(3) wants the citation in the message; here the citation had to be
   reconstructed afterwards. Nothing to fix in the code; something to fix in the merge habit.
6. **The durable log is empty for the day.** `docs/QA/DISCUSSION-LOG.md` has no 2026-10-18 entry, although
   four PRs carry substantive reviews (#93, #96, #101, #125) and #127 carries an architecture decision on
   row 3. Under `AGENTS.md` §11.6 those exchanges exist only in the PR comments, which is the medium that
   hid the conversation on 2026-10-17. This ledger links each one; the log entries are still owed.
7. **The UI-only PRs rest on widget tests.** #107 (104), #109 (105), #116 (112) and #142 (126) are Flutter
   `flutter test` runs with no live-stack walk-through and no device. That is the right gate for the code
   they changed; it is not a claim the screens work end to end, and none of the four PRs makes that claim.
8. **#111 fixed the probe, not the server: a token minted in the revocation second survived.**
   *(Added 2026-10-19 — Claude's condition 1b on #143; this debt was missing from the day's list.)*
   Claude's review named it at `sessions.ts:59`: the revocation path compared the token's `iat` with
   `< before`, so a token minted in the same second as the revocation stayed valid. #111's `F8` check
   only *waited* for the second boundary — that makes the probe deterministic, it does not close the
   hole, and no API line changed in #111. A reader of the row above would have thought the ADR-0014
   session story was clean.
   **Fixed 2026-10-18 by [#156](https://github.com/handfulofluck-lab/osra/pull/156)** (`0d0418c`,
   19:40:02Z; issue [#117](https://github.com/handfulofluck-lab/osra/issues/117) closed 19:40:04Z), read
   at `1733d83`: revocation is a per-parent counter (`services/api/src/lib/sessions.ts:114`,
   `incrby`), a token is refused when its `sv` is lower than the current counter (`:128-129`), and the
   legacy no-`sv` fallback compares `iat` inclusively so the revocation second is dead there too
   (`:133-134`). **#156 is author-run** — the same-second `F8`/`N2` assertion has only my run, so the
   fix is on record but the live proof is not independent; it is the successor ledger's first re-run
   (§5 there, Block A item 1).

## 4. What a verifier should re-run first — in risk order

Ordered so that a single session covers the changes where a defect is expensive (authorization, a
central middleware, a security default) before the ones where it is cosmetic. **One live gate at a
time, ≥ 60 s apart** — the shared API rate-limits at 200 req/min and the later gate will abort with exit 2
(that is the #114/#129 contract, not a failure).

1. **#139 — `requireFamily` epoch + family scoping, nonce fail-closed, MFA re-enrol.** Highest risk: it
   changes the middleware every family-scoped route passes through, and its live half was never run on
   the branch. First run the unit suite on the merged tree, then probe and e2e against a server built from
   `main` (§5.3) — not the shared `:3000` if you can avoid it, and if you cannot, say so in the record.
2. **#130 — WebSocket is ticket-only.** Closes a HIGH auth bypass. What matters is the negative case:
   `?token=` must be a **401 `ticket_required`**, not 404 and not an upgrade. Probe L6–L9 pin it.
3. **#141 — device register/pair need `devices`.** Credential issuance: a co-parent without the permission
   must get `403 {"error":"permission_required","permission":"devices"}` on both routes, and `/register`
   must not echo `internalSecret` or `pushToken`. Probe N6b/N6c plus the setup secret check.
4. **#125 — location ping auth and own-child scoping.** A device token must get `403 cross_child_forbidden`
   on a sibling child, and a forged reset-purpose token must get `401`. Antigravity's record is already at
   the merged head, so this is a confirmation run rather than a repair — worth doing because that sign-off
   landed 23 s *after* the merge, so no merge message ever cited it.
5. **#140 — the desktop PIN has no default, HTTPS inspection validates upstream.** The security default is
   the whole point: with no PIN configured, `lock`/`bedtime` must refuse to arm; with
   `FS_HTTPS_INSPECT_ALLOW_INSECURE` unset, a self-signed upstream must be rejected. `dotnet test` covers
   the policy; the pairing dialog and a live proxy handshake need a desktop row nobody has run.
6. **#93 — the digest claim.** Read `services/api/src/jobs/digestScheduler.ts:107-122` first: F1 is open
   (§3, item 1). Then run the schedule tests and decide whether F1/F2/F3 block a release.
7. **#124 — device silence, self-scoped telemetry, push-token shape.** No probe check exists; the three
   things to try by hand are the ones the PR lists in §5 (A→B telemetry 403, push-token without
   `internalSecret`, and a real `device_silent` alert after backdating `lastSeen`).
8. **#131 — boot FGS guard, and the live call sites #132 named.** Both flavours on a clean build, then
   the reboot row in `docs/TESTING.md` §5 with location denied and granted — it needs a human unlock
   after `adb reboot` (`AGENTS.md` §9.3).
   **Amended 2026-10-19 (Claude's condition 3):** the reboot row exercises the boot path only. #132 was
   live in `AccessibilityMonitorService` and `CommandDispatcher.locate_now`, so the row must also run
   the while-in-use case below — a green boot path with an unguarded accessibility start is exactly the
   pass Claude warned about. #132 is fixed by #155; this case is what proves it on a handset, and it
   has never been run (the successor ledger records the same case as Block B item 5).

   Claim the lease first (§5.7); never send `lock`. The agent must be **paired** before step 2, or the
   decision short-circuits to `null` and the empty crash buffer proves nothing
   (`apps/child-android/app/src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt:262`).

   ```bash
   SERIAL=R5CW116Y6GF; PKG=com.familyshield.agent
   A11Y="$PKG/$PKG.services.AccessibilityMonitorService"   # full class name; the short form is dropped on One UI (TESTING.md:439)

   # 0. record the two toggles this run changes, so the release can put them back (AGENTS.md §9.3)
   adb -s $SERIAL shell settings get secure enabled_accessibility_services
   adb -s $SERIAL shell settings get secure accessibility_enabled

   # 1. while-in-use only: fine + coarse granted, background explicitly not
   adb -s $SERIAL shell pm grant  $PKG android.permission.ACCESS_FINE_LOCATION
   adb -s $SERIAL shell pm grant  $PKG android.permission.ACCESS_COARSE_LOCATION
   adb -s $SERIAL shell pm revoke $PKG android.permission.ACCESS_BACKGROUND_LOCATION
   adb -s $SERIAL shell dumpsys package $PKG | grep -E "ACCESS_(FINE|COARSE|BACKGROUND)_LOCATION"
   #   expect fine and coarse granted=true; ACCESS_BACKGROUND_LOCATION must not be granted
   #   `pm grant` can report success while appops still says ignore (ANTIGRAVITY-INBOX.md:83):
   adb -s $SERIAL shell appops get $PKG FINE_LOCATION        # expect "FINE_LOCATION: allow"

   # 2. nothing of ours in front, clear the crash buffer, then enable accessibility -> the service
   #    binds in the background and runs the 60-s location tick there
   adb -s $SERIAL shell input keyevent KEYCODE_HOME
   adb -s $SERIAL logcat -b crash -c
   adb -s $SERIAL shell settings put secure enabled_accessibility_services "$A11Y"
   adb -s $SERIAL shell settings put secure accessibility_enabled 1
   adb -s $SERIAL shell settings get secure enabled_accessibility_services   # must echo the full name

   # 3. two minutes, then the assertion: an empty crash buffer and no LocationService
   sleep 120
   adb -s $SERIAL logcat -b crash -d                          # expect no com.familyshield.agent frame
   adb -s $SERIAL logcat -b crash -d | grep -c "com.familyshield.agent"        # expect 0
   adb -s $SERIAL shell dumpsys activity services $PKG | grep -c LocationService  # expect 0
   # the positive control — without it "empty crash" could mean the tick never ran:
   adb -s $SERIAL logcat -d -s AccessibilityMonitor | grep "not starting LocationService"
   #   expect "... not starting LocationService: background_location_missing ... (#132)"

   # 4. the ack half of #155: send locate_now from the parent side, then
   #    GET /v1/devices/:id/commands/history — expect a failed ack with
   #    detail.reason = background_location_missing, not 200 and not a process death
   ```

   **Pass means:** steps 1–3 print as above (fine/coarse granted, no background grant, crash buffer
   empty after 120 s, `LocationService` not running, and the `background_location_missing` line present
   as the positive control), and step 4 shows the failed ack with that reason. An empty crash buffer
   *with* `LocationService` running is not a pass — it means the FGS started, so the guard did not
   engage. **Restore step 0's two values** — write the exact strings back with
   `settings put secure enabled_accessibility_services "<value>"` and
   `settings put secure accessibility_enabled <0|1>` (an empty string if that is what was there) — and
   re-grant background location only if the run revoked it. §9.3 asks for the previous values, not for
   "left working". #155 is JVM-proven only (`LocationStartPolicy.kt:41-49`,
   `AccessibilityMonitorService.kt:144-166`, `CommandDispatcher.kt:247`); this row is the hardware half.
9. **#129 / #114 / #111 — the gates' own failure modes.** Cheap, and they protect every later run: a
   stub answering 429 must abort with exit 2 and no `FAIL` line in both `qa-probe.mjs` and `e2e.mjs`.
10. **#127 / TR-21 — the hardware rows.** S1 and S1b are **NOT MEASURED**; one maintainer unlock (or the
    device PIN, which only the human may enter) turns S1 into a two-minute run.
11. **UI-only, last: #116, #142, #107, #109.** Flutter tests plus a look at the screen; nothing here can
    break another lane. #116's "never says sent" line is the one acceptance check worth reading in the
    test body rather than trusting the count.
12. **Docs-only, cheapest: #84, #96, #97, #98, #103, #104, #113, #115.** The check §6.5 asks for is a
    diff read: every cited `file:line` says what the text claims. `node scripts/check-docs-links.mjs`
    covers the links only.

## 5. The exact commands, on this machine

All paths are the ones this host actually uses. `127.0.0.1`, never `localhost` — the API binds IPv4 and a
`localhost` resolution to `::1` looks like a dead stack.

### 5.0 Secrets and the shared API

```bash
cd C:/KARIM/wt-<your-worktree>            # never the primary clone; never switch branches there
set -a; . /c/KARIM/tr-kimi/api-3000.env; set +a    # JWT_SECRET, INTERNAL_HMAC_SECRET, VAULT_KEY
curl -s http://127.0.0.1:3000/health/deep          # {"ok":true,"db":"up","redis":"up"}
```

The shared `:3000` instance is not yours to restart (`AGENTS.md` §6, ADR-0018). If the change under test
is not on `main`, run your own instance and point `API_BASE` at it (§5.3). Never run two live gates
concurrently, whoever owns them.

### 5.1 API unit suite

```bash
pnpm install --filter "@familyshield/api..." --frozen-lockfile
pnpm --filter @familyshield/api test                         # vitest run
cd services/api && npx tsc --noEmit && cd ../..              # type check (matches the PRs' evidence)
node scripts/check-probe-integrity.mjs --base origin/main    # must print 0 removed or demoted
node scripts/check-docs-links.mjs                            # 0 broken links
```

### 5.2 Live gates against the shared `:3000`

One at a time, **≥ 60 s between them**. The probe's `passed` total grows with each probe PR (109 before
#114, 120 after #130, 123 after #141) — quote the total you saw rather than trusting this line; what a
green run must show is `0 failed`, and e2e must show `69 passed, 0 failed`.

```bash
cd services/api
API_BASE=http://127.0.0.1:3000 node scripts/qa-probe.mjs
#   exit 0 = green; exit 2 = rate limited, wait 60 s and re-run; exit 1 = a real failure
sleep 65
DATABASE_URL="postgresql://familyshield@127.0.0.1:5432/familyshield" \
  API_BASE=http://127.0.0.1:3000 node scripts/e2e.mjs
#   without DATABASE_URL the erasure row-count check prints NOTE … skipped and is not evidence
```

### 5.3 A branch instance (when the change is not on `main`)

```bash
cd services/api
pnpm --filter @familyshield/api build                     # tsc → dist/
PORT=3100 DATABASE_URL="postgresql://familyshield@127.0.0.1:5432/familyshield" \
  node dist/server.js                                      # shares Postgres/Redis; do not touch :3000
# in a second shell, from services/api, with the env from §5.0:
API_BASE=http://127.0.0.1:3100 node scripts/qa-probe.mjs
sleep 65
DATABASE_URL="postgresql://familyshield@127.0.0.1:5432/familyshield" \
  API_BASE=http://127.0.0.1:3100 node scripts/e2e.mjs
# then stop the :3100 process before you do anything else
```

This is the shape #125, #130 and #141 used. A gate run against `:3000` while your branch is not
deployed is a regression check on `main`, not evidence for the PR — say which stack you used (#139's
record shows why that distinction matters).

### 5.4 Flutter (parent app)

```bash
cd apps/parent-app
C:/KARIM/tools/flutter/bin/flutter test
C:/KARIM/tools/flutter/bin/flutter analyze
```

### 5.5 Android (both flavours — ADR-0016)

```bash
cd apps/child-android
export ANDROID_HOME=C:/KARIM/tools/android-sdk
export JAVA_HOME=C:/KARIM/tools/jdk-17
./gradlew testPlayDebugUnitTest testFullDebugUnitTest assemblePlayDebug assembleFullDebug
# the per-flavour totals the PRs quote ("tests=251 failures=0") are the sums over
#   app/build/test-results/test<Flavour>DebugUnitTest/*.xml
# and the human-readable report is app/build/reports/tests/test<Flavour>DebugUnitTest/index.html
# manifest claims (#100, #106, #131), on the built APKs:
"$ANDROID_HOME"/build-tools/*/aapt2.exe dump permissions app/build/outputs/apk/play/debug/app-play-debug.apk
```

### 5.6 Windows agent (xunit)

```bash
cd apps/agent-desktop
C:/KARIM/tools/dotnet/dotnet.exe test tests/FamilyShield.Agent.Tests
# one suite:
C:/KARIM/tools/dotnet/dotnet.exe test tests/FamilyShield.Agent.Tests \
  --filter "FullyQualifiedName~ParentPinPolicyTests|FullyQualifiedName~HttpsInterceptionTests"
```

Beware the two documented traps: the real `LockWorkstationAction` locks your session if it is not stubbed,
and an install with no PIN refuses to arm by design — a "lock did nothing" result may be the fix working.

### 5.7 Hardware (only with the lease)

```powershell
.\scripts\hardware\phone-claim.ps1 -Action Claim -Owner "<agent>" -Purpose "TR-21: S1 re-run"
.\scripts\hardware\phone-claim.ps1 -Action Status
```

Post the lease line on the board (`AGENTS.md` §9.2), and release with `-LeftState` after clearing every
restriction (§9.4). The keyguard PIN is the human's (`AGENTS.md` §9.3); the app PIN is the app PIN and is
never a keyguard credential — that confusion cost the 2026-10-18 hardware run its S1 row (TR-21, #127).

### 5.8 Cleanup — do this whether the run passed or failed (`AGENTS.md` §7)

```bash
C:/KARIM/tools/pg/pgsql/bin/psql.exe -h 127.0.0.1 -U familyshield -d familyshield \
  -f services/api/scripts/cleanup-test-data.sql                        # dry run
C:/KARIM/tools/pg/pgsql/bin/psql.exe -h 127.0.0.1 -U familyshield -d familyshield \
  -v apply=1 -f services/api/scripts/cleanup-test-data.sql             # applies; expect "OK: 1 family"
node services/api/scripts/cleanup-test-redis.mjs                       # dry run
node services/api/scripts/cleanup-test-redis.mjs --apply
```

Expected end state: one family (`Demo Family`), child `Alex`, device `Pixel 7a`, nothing else.

## 6. What this ledger is not

- **Not a re-verification.** No gate in §2 was re-run to write this file; every number is quoted from the
  merge message or the PR body/comment that claims it. The only command I ran for this document is
  `node scripts/check-docs-links.mjs`, whose raw output is in the pull request's gate section. The
  **2026-10-19 amendments in §0** add no run either: they are the `file:line` re-reads at `1733d83`, the
  PR/issue records they name, and one `grep -rnE 'app PIN [0-9]{4}'` over `docs`/`scripts` (§0, condition 2).
- **Not a status upgrade.** Nothing here turns an author's run into verification, and #125's sign-off is
  recorded with its timestamp so a reader can see it landed after the merge.
- **Not a substitute for a `TR-*` row.** When a verifier does re-run a row above, the record belongs in
  [`TEST-REQUESTS.md`](TEST-REQUESTS.md) as its own request with raw output, and this file can then cite
  it — that is the file working, not this one going stale. Dates in filenames are point-in-time records
  (`docs/README.md` conventions): a later batch gets its own ledger.
