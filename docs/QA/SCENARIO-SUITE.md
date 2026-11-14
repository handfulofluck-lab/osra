# Real-device parent/child scenario suite

**Owner:** Claude (architecture + testing). **Status:** draft v1, 2026-11-12, asked for by the maintainer.
**Roadmap rows:** `S0`–`S5` in [`../ROADMAP.md`](../ROADMAP.md), one per phase. **Results:** the tracking
issue named in the roadmap's "Real-device scenario suite" section, one comment per run.

The hardware rows we have run so far each prove one PR's claim on one handset. This suite is different in
kind: each scenario is a **family story that crosses two real devices**, a parent's and a child's, through
a real backend, and it passes only when the second device shows the effect. It reuses the rules already in
force and does not restate them: the lease and reset order ([`DEVICE-REGISTER.md`](DEVICE-REGISTER.md),
[`../TESTING.md`](../TESTING.md) §5.0), "a hardware PASS names the build kind"
([`TESTING-STRATEGY.md`](TESTING-STRATEGY.md) §3b), and "every finding comes with its fix"
(`AGENTS.md` §12).

## 1. The test bed

| Id | Device | Host | Notes |
|---|---|---|---|
| DEV-01 | Samsung Galaxy Z Flip4, Android 16 (`R5CW116Y6GF`) | Windows PC, USB `adb` | The maintainer's personal handset with a SIM. Never change its clock, never `dpm remove-active-admin`, never type its unlock code, never print real numbers or messages from it |
| DEV-02 | iPhone 13 (test only, child Apple ID) | MacBook, own XCUITest driver | No personal data. No Airplane Mode (it breaks the driver), no Apple ID, date or time changes |
| DEV-03 | MacBook M2 (test only) | itself | iOS build host, and the macOS child once 5.9 has a build |
| DEV-04 | Windows PC | itself | Test host, and the Windows child once 5.4 has an installer. A clean Windows 11 machine is still needed for 5.4's own acceptance |
| EMU-01 | `osra-test` Android emulator | Windows PC | The only place for scenarios that need a clock change or seeded SMS/call history |

**Pairs.** A scenario names the pair it runs on.

| Pair | Parent | Child | Backend | Use |
|---|---|---|---|---|
| A | parent app on DEV-01 | Android agent on DEV-01 | local API over `adb reverse` | Fast lane. Two apps, one handset: good for timing child-side effects, not for push or network claims |
| B | parent app on DEV-02 | Android agent on DEV-01 | HTTPS staging | The main cross-device pair: iPhone parent, Android child |
| C | parent app on DEV-01 | OSRA Kids on DEV-02 | HTTPS staging | The reverse: Android parent, iPhone child |
| D | parent app on DEV-01 or DEV-02 | Windows client on DEV-04 | HTTPS staging | Opens when 5.4 ships an installer |
| E | parent app on DEV-01 or DEV-02 | Mac client on DEV-03 | HTTPS staging | Opens when 5.9 ships a build |
| X | parent API calls from the host | EMU-01 | local API | Clock and seeded-history scenarios only |

Staging is brought up on demand, so pairs B to E run in **staging windows**: one window serves every
queued B/C scenario, then staging goes down again.

## 2. What a scenario is

Every scenario has the same five parts, and a run that lacks one is not a PASS.

1. **Story.** One sentence a parent would recognise.
2. **Pair and builds.** The pair from §1, and each app's build kind and sha (`classify-build.ps1`).
3. **Steps.** Parent action, then the child-side observation, by coordinates and `screencap` on DEV-01
   (no `uiautomator dump` while a row depends on accessibility-service state) and by the XCUITest driver
   on DEV-02.
4. **Measure.** A number or a state read from the second device or the server (API log, Postgres row,
   `logcat -b events`), with its limit. Latencies come from timestamps, never from a stopwatch.
5. **Restore.** The before-values recorded at the start are put back, the pairing is cleared, the lease is
   released with its left-state.

A scenario that needs the maintainer's hand (a QR held to the camera, an unlock after a fold or reboot, a
real phone call, an Apple parent approval) is tagged **hands**. Hands scenarios are saved up and run
together in one short session.

## 3. The catalogue

Status for every row is ⬜ until a run is recorded on the tracking issue. "Row" is the roadmap item the
scenario exercises; a scenario never replaces that item's own acceptance, it shows the item working in a
family story.

### Phase 0 — the bed itself (`S0`)

| Id | Scenario | Pair | Measure |
|---|---|---|---|
| SC-0.1 | Preflight: lease claimed, serial and model match, builds classified, backend healthy, before-values saved | all | every check green in under 2 min |
| SC-0.2 | Restore: after a run the phone is unpaired, unlocked, with accessibility, overlay, locale and stay-awake back at their before-values | all | diff of before/after values is empty |
| SC-0.3 | A stuck lock is recoverable: lock from the parent, lose the parent session, recover by the documented order | A | phone usable again in under 5 min, no shell admin removal |

### Phase 1 — Android child (`S1`)

| Id | Scenario | Pair | Row | Measure |
|---|---|---|---|---|
| SC-1.1 | Lock now, unlock now | A, B | 1.3, 1.5 | overlay up in ≤ 5 s and down in ≤ 5 s, app backgrounded |
| SC-1.2 | Lock survives Home, Recents, Settings and a reboot (hands) | A | 1.3 | overlay back in ≤ 3 s each; re-applied after first unlock |
| SC-1.3 | Bedtime starts and ends; the dialer and SOS stay usable | A | 1.3 | block screen on a non-essential app; emergency dialer opens |
| SC-1.4 | Block one app, then allow it again | A, B | 3.4 | block screen within one command poll; app opens after allow |
| SC-1.5 | Daily time limit reached, parent adds time | A | 2.4 | "Daily limit reached" at the limit; app usable after the grant |
| SC-1.6 | Pause the internet, lift the pause | A, B | 1.4 | 100 % loss while paused; back in ≤ 5 s |
| SC-1.7 | Blocked site and SafeSearch in Chrome and one other browser | A | 1.4 | blocked domain fails in both; Google search is forced safe |
| SC-1.8 | Ring a silent phone; locate now | A, B | 1.7 | alarm at max with volume 0, PIN to stop; fix under 30 s old on the parent map |
| SC-1.9 | Child presses SOS | A, B | 1.x | parent sees the SOS alert with location in ≤ 10 s |
| SC-1.10 | Child tries to remove protection: uninstall, admin off, force-stop, VPN off, accessibility off | A | 1.1, 1.9 | each attempt refused or alerted within its limit (the bypass probe's ten rows, told as one story) |
| SC-1.11 | Phone offline for 30 min, then back | A | 2.3 | queued commands apply on reconnect, in order, none lost; parent shows pending then delivered |

### Phase 2 — backend through two devices (`S2`)

| Id | Scenario | Pair | Row | Measure |
|---|---|---|---|---|
| SC-2.1 | An alert reaches the parent phone with the parent app swiped away | B, C | 2.1 | notification shown, time recorded; no notification after sign-out |
| SC-2.2 | Command status is honest | B | 2.3, 3.6 | parent never shows "sent" for an unacknowledged command |
| SC-2.3 | Consent revoked by the parent | A | 0.1, 3.7 | ingestion refused (428) and the child shows the reduced state; safe-direction commands still work |
| SC-2.4 | A day of use shows correctly in the parent's report | A | 2.4, 3.5 | per-app minutes within ± 1 min of Android's own usage stats |
| SC-2.5 | WhatsApp message arrives with WhatsApp in the background | A | 2.6 | one scan event for the message, none for our own test rows' neighbours |
| SC-2.6 | Unlink a child, then delete the family | A | 2.4 | child returns to the pairing form; zero rows left for the family |

### Phase 3 — parent app (`S3`)

| Id | Scenario | Pair | Row | Measure |
|---|---|---|---|---|
| SC-3.1 | First run: sign up, pair by QR, see the child online (hands) | B, C | 3.2 | under 5 min from first launch, no help |
| SC-3.2 | The same journey in Arabic, right to left | B, C | 3.1 | no English, no clipped or mirrored-wrong element; screenshots go to the Arabic and UI/UX Bureaus |
| SC-3.3 | MFA on, sign out, sign in, reset the password | B | 3.3 | each step completes; old sessions are refused |
| SC-3.4 | Pick apps from the child's real app list and set a rule | B | 3.4 | the picked app is blocked on the child; essentials cannot be picked |
| SC-3.5 | A second guardian with limited permissions | B | ADR-0014 | sees only what the permissions allow; export stays owner-only |
| SC-3.6 | Two children, two phones, rules do not cross | B + C | 3.x | a rule for one child never lands on the other |
| SC-3.7 | Light and dark theme through the core journey | B | 3.8 | screenshots, both themes, to the UI/UX Bureau |

### Phase 4 — AI (`S4`)

| Id | Scenario | Pair | Row | Measure |
|---|---|---|---|---|
| SC-4.1 | A worrying message in English on the child becomes a parent alert with the right category | A, B | 4.1 | alert present with category; text comes from the committed evaluation set |
| SC-4.2 | The same in Arabic | A, B | 4.1 | as SC-4.1 |
| SC-4.3 | Ordinary chatter raises nothing | A | 4.3 | zero alerts for 20 benign rows |
| SC-4.4 | The scorer is unreachable | A | 4.1 | the offline fallback still flags the English rows; nothing is lost when it returns |

### Phase 5 — stores, iOS, computers (`S5`)

| Id | Scenario | Pair | Row | Measure |
|---|---|---|---|---|
| SC-5.1 | iPhone child: pair, appear online, locate | C | 5.5 | online in the parent app; fix under 30 s old |
| SC-5.2 | iPhone child: block an app, bedtime shield, allow again | C | 5.5 | shield shown, then gone |
| SC-5.3 | iPhone child in Arabic: shields and status screen | C | 5.5, #654 | no English on the shield |
| SC-5.4 | iPhone child asks the parent, parent answers | C | #600 | the child hears the answer |
| SC-5.5 | iPhone child tries to remove protection ([Ahmed's list](IOS-REMOVAL-ATTEMPTS.md), 18 rows) | C | 5.5 | each attempt refused or alerted |
| SC-5.6 | Install both apps from the store tracks and pair (hands) | B, C | 5.2, 5.6 | Play internal track and TestFlight builds, no developer tools |
| SC-5.7 | No plan, then a plan | B | 5.12 | `402 plan_required` shown as a plan screen, lifted after a test purchase |
| SC-5.8 | Add a Windows computer from the parent app | D | 5.4 | paired with no server field; a blocked site fails for a Standard user |
| SC-5.9 | Add a Mac from the parent app | E | 5.9 | as SC-5.8 on macOS |
| SC-5.10 | One family, every platform at once | B + C + D + E | 5 gate | one rule change lands on every child device |

## 4. Making it fast

A hardware row costs about fifteen minutes today, and most of that is setup and tidy-up, not the
measurement. The plan below is ordered by how much time each step saves.

1. **Three lanes at once.** DEV-01 on the PC, DEV-02 on the Mac and EMU-01 share nothing, so a pair-A
   batch, an iPhone batch and a clock batch run in parallel. Only pairs B and C need both phones.
2. **One runner, not hand-typed setup.** `scripts/hardware/scenario.ps1` reads a scenario manifest and does
   the preflight (SC-0.1), saves before-values, makes the evidence folder, runs the steps, restores
   (SC-0.2) and prints the result table for the issue. It has a dry-run mode with no device so CI can test
   it.
3. **A family in one call.** A seed helper creates a throwaway family with a child, a pairing code and
   rules that will not ambush the run (no default bedtime or school hours), and deletes it afterwards.
4. **Drive the parent by API unless the parent screen is what is measured.** Phase 1 and 2 scenarios
   measure the child and the server; Phase 3 scenarios use the real parent UI.
5. **Batch by state.** One pairing serves every scenario that can share it; the order inside a batch goes
   from least to most disruptive, tamper scenarios last.
6. **One hands session.** Every hands scenario waits for a single session with the maintainer, planned to
   fit in fifteen minutes.
7. **One staging window per batch.** B/C scenarios queue until there are enough to justify bringing
   staging up.
8. **Smoke and full.** Ten scenarios (SC-0.1, 1.1, 1.4, 1.6, 1.8, 1.9, 2.1, 3.1, 5.1, 5.2) form the smoke
   run for every release candidate, aimed at thirty minutes. The full catalogue runs before a gate claim.
9. **Evidence by default.** Screenshots, the events log and the server rows are collected by the runner,
   so a FAIL arrives with what the fixer needs and is not re-run just to gather it.

## 5. Who does what

| Member | Part |
|---|---|
| Claude | Owns the catalogue and the runs on every device; the only verifier; files each finding with its fix |
| Kimi Code | The seed helper and any test hook a scenario needs in the Android agent, API or parent app; fixes findings; merges |
| K31 | The scenario runner and its tests (code and tests only, no device, no secrets) |
| Ahmed | The iPhone removal-attempt list for SC-5.5, stable accessibility identifiers in OSRA Kids so the driver taps by name, and a security review of what the runner and seed helper expose |
| Arabic Bureau, UI/UX Bureau | Receive the Arabic and light/dark screenshots that SC-3.2, SC-3.7 and SC-5.3 produce |
| Antigravity | Silent by the maintainer's ruling of 2026-10-19; no part until he says otherwise |
| Maintainer | The hands session, staging spend, and anything that needs an account |

## 6. Recording a run

One comment on the tracking issue per run: date, pair, builds (kind and sha), a table of scenario id,
PASS / FAIL / NOT RUN, the measured value and its limit, and the evidence folder name. A FAIL links the
issue filed for it. A scenario that could not be measured is NOT RUN with the reason, never a PASS. When a
scenario's run closes a roadmap acceptance, the roadmap row is updated in a PR that cites the comment.
