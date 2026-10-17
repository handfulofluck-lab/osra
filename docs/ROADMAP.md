# OSRA roadmap — the KCL plan, item by item

Source: **OSRA Readiness Assessment & Plan** (2026-10-16, branch `KCL`, raw audits under
`docs/QA/KCL-2026-10-16/`). Six phases, five gates, 20 weeks. This file is the single status surface
for that plan; the GitHub program board (issue #50) mirrors its phase table. Update it **in the PR
that lands the change**, like `CHANGELOG.md` — a row may only move to ✅ with a tester's verification
or a merge sha beside it.

Maintainer decisions recorded 2026-10-16: two Android builds (Play + sideloaded "Full"); Phases 1 and 2
in parallel; AI on a hosted LLM first (DeepSeek), own model once the evaluation set exists; iOS built on
GitHub macOS runners and launched with the rest; Arabic RTL + Arabic AI pulled into early priorities;
Windows runs as a signed service (code-signing spend approved).

**Legend:** ✅ merged to `main` and tester-verified · 🟡 built, verified, waiting to merge · 🔵 in
progress · ⬜ not started · 🟥 blocked on a decision or a resource outside the repo.

**A gate is a measured result on hardware or against a live stack**, in the style of the adversarial
probe; a green unit suite does not open a gate.

## Progress at a glance (2026-10-17)

| Phase | Weeks | Gate | Items done | Status |
|---|---|---|---|---|
| 0 Stabilise | 1 | — | 4 / 5 | ✅ (branch pruning pending a go) |
| 1 Android credibility | 2–8 | 10 bypasses fail on hardware | 0 / 9 (1.1–1.2 🔵) | 🔵 |
| 2 Backend as a product | 4–10 | probe 0 targets, push lands | 5 / 6 (2.5 🟡 verified on hardware, merging) | 🟡 |
| 3 Parent app to store grade | 6–14 | parent pairs in 5 min | 0 / 9 | ⬜ |
| 4 AI that earns the word | 8–16 | recall ≥ 0.85 EN+AR | 0 / 5 | ⬜ |
| 5 Store and iOS | 10–20 | 20 families install without help | 0 / 7 (entitlement 🟥) | ⬜ |

Week 0 was 2026-10-16. The backend lane ran first because Phase 2 was pure API work that the testers
could verify without hardware; from 2026-10-17 the Android lane (Phase 1) is the critical path and gets
the lead's time until its gate passes.

## Phase 0 — Stabilise (week 1)

| # | Item | Acceptance | Status · evidence |
|---|---|---|---|
| 0.1 | PR #48 consent gating with the review fixes (ingestion returns 428 after revoke; safe-direction ops stay open) | probe J3 asserts ingestion 428 after revoke | ✅ #48 merged; J3 is a gating probe check |
| 0.2 | Parent app release manifest (`INTERNET`), Maps API key via `local.properties` | `flutter build apk --release` logs in, map renders | ✅ CI builds the release AAB and asserts `INTERNET` (`ci.yml` job `parent-app`) |
| 0.3 | `assembleRelease` + signed-APK check in CI | release build compiles and shrinks | ✅ `ci.yml` job `child-android` (debug key by design until the upload keystore secret is set) |
| 0.4 | Rotate the dev secrets in `start-backend.bat` | no committed secret is live | ✅ placeholders only; live values in env |
| 0.5 | Delete the fully-merged branches (`fix/*`, `feat/*`, `docs/*`, `ANTIGRAVITY`) | remote branch list = active lanes only | ⬜ 37 remote branches today; bundles exist under `~/osra-backups/`. Needs a one-word go from the maintainer, then the lead deletes and lists them in the log |

## Phase 1 — Android credibility (weeks 2–8) — gate: the ten bypasses fail on hardware

| # | Item | Acceptance | Status · evidence |
|---|---|---|---|
| 1.1 | Device Admin receiver + uninstall block + parent PIN to disable; Accessibility detects Settings/uninstall/force-stop screens and overlays them | `adb uninstall` and Settings › Uninstall both fail without PIN; alert within 60 s if admin revoked | 🔵 `feat/android-tamper-and-lock@99f6d1e` — receiver, PBKDF2 PIN, tamper tiers, encrypted store written (ADR-0010 draft), **not wired yet** |
| 1.2 | Remove the unauthenticated Re-pair; require parent PIN or server-issued unpair | no path from the child UI clears pairing | 🔵 same branch |
| 1.3 | Lock that holds: lock-task mode (or device-owner `lockNow`), state persisted, re-applied on boot, overlay permission in onboarding | lock survives Recents swipe and reboot | ⬜ |
| 1.4 | Local `VpnService` DNS/SNI sinkhole: pause-internet, category blocklist, SafeSearch via DNS CNAME, YouTube restricted via DNS | blocked domain fails in Chrome, Firefox and an in-app WebView; pause cuts all traffic | ⬜ |
| 1.5 | Real FCM: `google-services.json`, gms plugin, data messages for commands; poll stays as fallback | lock lands in < 5 s with the app backgrounded | ⬜ (server side done in 2.1: `src/lib/push/notify.ts`) |
| 1.6 | Guided, verified onboarding: Accessibility, Usage Access, Overlay, Battery exemption, Device Admin, Notification Listener, Background Location — each checked on return, OEM guidance (Samsung, Xiaomi) | pairing cannot complete with a required permission missing | ⬜ |
| 1.7 | Ring forces alarm stream to max, wake lock, screen on, stop needs PIN; Locate takes a fresh high-accuracy fix with timeout | ring audible at volume 0; locate fix < 30 s old | ⬜ |
| 1.x | **Found on hardware (TR-07):** the SOS quick-settings tile did nothing on Android 14+ (`startActivityAndCollapse(Intent)` removed on API 34); the child's only SOS entry was dead on every current phone | tile tap opens `SosActivity` on API 34+ | 🟡 #73 (one method, PendingIntent on 34+), verified on the Flip4 — the TR-07 201s are from that build |
| 1.8 | Encrypted prefs for JWT/HMAC, release signing, `targetSdk 35`, minify, cleartext off outside debug | Play pre-launch report passes | ⬜ (encrypted store exists on the 1.1 branch; the rest open) |
| 1.9 | Device-level adversarial probe: an `adb`-driven script that attempts the top ten bypasses, run on hardware before merge | script under `scripts/`, run recorded in the PR | 🔵 seed landed with #74: `scripts/hardware/android-signing-tr07.ps1` (pair via `uiautomator`, SOS via the QS tile, API/DB checks, §7 cleanup). The ten bypass attempts are the remaining work — this is what opens the Phase 1 gate |

Two builds (decision 1): Play flavor (no calls/SMS, limited social, Accessibility declaration + video)
and Full flavor (calls/SMS/WhatsApp; `isMonitoringTool=child_monitoring`; sideloaded, Play Protect
warning accepted). Both flavors land with 1.8.

## Phase 2 — Backend as a product (weeks 4–10) — gate: probe 0 targets, push lands on a closed app

| # | Item | Acceptance | Status · evidence |
|---|---|---|---|
| 2.1 | Push to parents: FCM + APNs behind one interface; every alert type calls it; parent app registers tokens | alert on the child device reaches the parent phone with the app closed | ✅ #51 (ADR-0011), TR-02 verified by Kimi + Antigravity. ⚠️ end-to-end on a phone waits on the parent app registering a token (3.x) |
| 2.2 | Email provider: password reset, invites, weekly digest cron | reset email delivered; digest Sunday 18:00 family-local | ✅ #51 (`src/jobs/digestScheduler.ts`, `src/lib/email/templates.ts`) |
| 2.3 | Persistent command queue (id, status, ack, expiry); agents ack; parent UI shows delivered/pending/failed | Redis restart loses no command; UI never says "sent" for an unacked command | ✅ #52 (ADR-0012), TR-01 verified on non-UTC hosts; parent-UI half is 3.x |
| 2.4 | Usage model: `AppUsageDaily` + `WebVisit`, nightly rollup, 90-day retention, erasure cascade | weekly report correct after a Redis flush; erasure leaves zero rows | ✅ #64 (ADR-0013), TR-06 verified by Kimi (0 rows in 13 tables, counted in Postgres); finding #66 fixed on #65 |
| 2.5 | Close J2 (timestamp + nonce) and J6 (no global fallback), fix co-parent role, `jti` on access tokens, encrypt `mfaSecret` | probe 0 targets | 🟡 #65 (ADR-0014) verified both halves: Kimi (software, probe 109/0) and the KCL lead on the maintainer's Galaxy Z Flip4 / Android 16 (TR-07: SOS → 201 with v1 on and off, skew −1 s). **Gate met**: #74 makes v1 opt-in → probe **0 targets by default**. Waiting to merge: #65 → #73 → #74 |
| 2.6 | Durable on-device scan queue + notification-listener capture (WhatsApp items 1 and 2) | a message received with WhatsApp backgrounded produces a scan event | ⬜ next in the backend/Android seam |
| 2.x | Added from review: WebSocket `ready` frame (TR-05), Redis hygiene #56/#57, probe-integrity CI gate | — | ✅ #63, #68, #69 |

## Phase 3 — Parent app to store grade (weeks 6–14) — gate: a non-engineer parent pairs in 5 minutes

| # | Item | Acceptance | Status |
|---|---|---|---|
| 3.1 | `flutter_localizations` + `.arb` for EN and AR with full RTL | Arabic screenshots reviewed by a native speaker | ⬜ (pulled early by decision 6) |
| 3.2 | Onboarding flow; QR pairing | 5-minute first-run test completes pairing | ⬜ |
| 3.3 | MFA enrolment, password reset, settings | — | ⬜ |
| 3.4 | Installed-app list from the device for app rules | — | ⬜ |
| 3.5 | Daily/weekly trend charts and browsing history (reads `/v1/reports/usage`, `/v1/reports/web`) | — | ⬜ (API done in 2.4) |
| 3.6 | Command delivery status (delivered / pending / failed) | UI never says "sent" for an unacked command | ⬜ (API done in 2.3) |
| 3.7 | Consent revoke/status screen | — | ⬜ |
| 3.8 | Dark theme and a real design system | `flutter analyze` clean | ⬜ |
| 3.9 | iOS target with the same codebase; push-token registration (FCM/APNs) | app runs on both targets | ⬜ |

## Phase 4 — AI that earns the word (weeks 8–16) — gate: recall ≥ 0.85 on self-harm and grooming at precision ≥ 0.6, EN and AR

| # | Item | Acceptance | Status |
|---|---|---|---|
| 4.1 | Hosted LLM scorer (DeepSeek) with a strict JSON schema; regexes stay as the offline fallback | Arabic text no longer scores "safe" by default | ⬜ 🟥 needs `DEEPSEEK_API_KEY` as a repository secret |
| 4.2 | Labelled evaluation set: ≥ 2,000 EN + 2,000 AR snippets across the seven categories, child-age context | set committed, provenance documented | ⬜ |
| 4.3 | Precision/recall per category published in the repo; eval runs in CI | numbers in `services/ai-engine/EVAL.md` | ⬜ |
| 4.4 | Model shipped as an artifact the compose file actually mounts (own model, once 4.2 exists) | `docker compose up` scores without the fallback | ⬜ |
| 4.5 | WhatsApp call metadata (who/when/how long — never content) | call row in the timeline | ⬜ |

## Phase 5 — Store and iOS (weeks 10–20) — gate: 20 families install from Play and TestFlight without help

| # | Item | Acceptance | Status |
|---|---|---|---|
| 5.1 | Apple Family Controls **distribution** entitlement requested (gates all iOS work) | request filed | 🟥 maintainer action — file now, approval sets the iOS date |
| 5.2 | Play: upload key, AAB, privacy policy, data-safety form, Accessibility disclosure + video, IARC, internal track | listing passes review | ⬜ |
| 5.3 | Closed testing with 20 families | 20 installs without help | ⬜ |
| 5.4 | Windows: MSIX installer, code-signing certificate, run as a service with a watchdog, env-var overrides removed, PIN synced from the parent account | agent survives Task Manager | ⬜ (spend approved) |
| 5.5 | iOS: Xcode project with App Group + three extension targets, FamilyActivityPicker selection, rule sync + APNs, CoreLocation | builds on the GitHub macOS runner | ⬜ |
| 5.6 | TestFlight build | installs on a parent's phone | ⬜ |
| 5.7 | Store listing copy EN/AR, screenshots | — | ⬜ |

## Needs the maintainer (open)

- Phase 0.5: a go to delete the merged branches.
- Merges: #70, #72, #65 → #73 → #74 (the lead's merge write on its own PRs is blocked; the maintainer merges).
- Phase 4.1: `DEEPSEEK_API_KEY` as a repository Actions secret.
- Phase 5.1: Apple Family Controls distribution entitlement request.
- Phase 5.4: the code-signing certificate purchase (approved; needs the purchase).
