# OSRA — Publishing Readiness Assessment
**Date:** 2026-09-17 · Scope: Android (Play) + Windows desktop

## Ownership and verification (role split of 2026-10-17)

This checklist predates the current lane split; the rows below remain the checklist, and
[`../../AGENTS.md`](../../AGENTS.md) §1 is the live statement of who may act on them.

- **Kimi Code (development lead)** — implements, owns `main` and is responsible for the release: the
  AAB/APK build, the signing wiring, the store-listing copy and the release PR.
- **Antigravity (testing)** — runs the gates and the hardware rows. A store submission is a release
  claim like any other, so the release PR cites the testing lane's run before it merges: owning `main`
  means owning the merge, not being trusted on the author's own word (`AGENTS.md` §1 and §6.5 — the
  author of a change is never its only verifier).
- **Claude (KCL lead)** — makes the architectural decisions and records them as ADRs, reviews designs
  and writes tests/checklists; does not merge.
- **Human maintainer** — holds every row that needs an account, a purchase, a legal answer or a store
  identity: Play Console and App Store Connect, the Apple entitlement, the upload keystore, the Windows
  code-signing certificate, the privacy policy, the data-safety form and the IARC questionnaire; and
  makes the final call on scope.

The suite numbers under "Where OSRA stands today" are the **2026-09-17 snapshot** and are not updated
in place; current counts, shas and their verification state are in
[`../../CHANGELOG.md`](../../CHANGELOG.md) and [`../ROADMAP.md`](../ROADMAP.md).

## What the pasted "Gemini tools" are (honest framing)

Gemini for Desktop, Project IDX, Android Studio's assistant, Cursor, Goose, OpenCode and
Warp are **development assistants** — they help write/debug code. They do **not** test an
app for store publishing, and none of them replace device testing, store review, or the
requirements below. (We already use the same *class* of tooling — Kimi Code subagents —
for the development side; that's how this codebase was built and QA'd.)

## Where OSRA stands today — automated verification

**The counts that used to sit here were stale.** They read 178/178 API, 146/146 Android JVM, 161/161 Windows,
89/89 parent and 44/44 E2E; on 2026-11-16 the same suites stand at 205+ vitest, 1117 Android JVM tests, 185
Windows, 103 parent and a 56-check E2E, and they move every day. A table nobody re-runs is worse than no table:
it gets quoted at review time as if it were current.

So this document no longer carries numbers. The current result for any commit is the CI run on that commit —
`ci.yml` plus each suite's own workflow (`api.yml`, `parent-app.yml`, `child-android.yml`, `agent-desktop.yml`,
`ai-engine.yml`) — and the release record cites the run ids, not a copy of them (`RELEASING.md` R5).

What these suites still do not replace: device testing, store review, and every row below.

## Google Play — what's required before publishing (current gaps)

| Requirement | Status | Action |
|---|---|---|
| `targetSdk 35` | ✅ met (child agent and parent app) | — |
| Release signing (own keystore) | 🟡 **plumbed, key not yet issued** | `build.gradle.kts` reads `OSRA_UPLOAD_KEYSTORE`, `OSRA_UPLOAD_KEYSTORE_PASSWORD`, `OSRA_UPLOAD_KEY_ALIAS`, `OSRA_UPLOAD_KEY_PASSWORD` from `android/local.properties` or the environment; CI materialises the keystore from the `OSRA_UPLOAD_KEYSTORE_B64` secret and builds the **AAB** on every run (falls back to the debug key when unset). Maintainer action: `keytool -genkeypair -v -keystore upload.jks -alias upload -keyalg RSA -keysize 2048 -validity 10000`, then `base64 -w0 upload.jks` into the secret. Also set `MAPS_API_KEY`. |
| 16 KB page-size compatibility (Android 15+) | 🟡 AGP 8.4 / current NDK — verify with `zipalign`/`apkanalyzer` on the AAB | Run the Play pre-launch report; bump NDK if flagged. |
| Privacy policy URL | 🟡 **page exists, HTTPS broken** | The policy is written and deployed: `site/privacy/index.html`, published by `.github/workflows/site-pages.yml`. Measured 2026-11-16: `http://osratech.com/privacy/` returns 200 with `<title>OSRA privacy policy</title>`, and `https://osratech.com/privacy/` **fails the TLS handshake** (`SEC_E_WRONG_PRINCIPAL` — the certificate does not match the name). Cause: DNS for `osratech.com` points at GitHub Pages (185.199.108-111.153) but the Pages domain challenge record `TXT _github-pages-challenge-handfulofluck-lab.osratech.com` does **not** exist, so no certificate is issued. Maintainer action: add that TXT record with the value GitHub shows under *Settings → Pages → Custom domain*, wait for the certificate, tick **Enforce HTTPS**. Do not hand Play an `http://` policy URL for a parental-control app. |
| Data-safety form | ❌ not filled | Declare location, app activity, messages metadata; note encryption. |
| App content rating (IARC questionnaire) | ❌ not done | Answer in Play Console. |
| Test track first (internal/closed) | 🟡 APKs ready | Upload `OSRA-ChildAgent.apk` (or AAB) to an internal track with the test family. |
| Accessibility-service disclosure | 🟡 description exists | Play requires a prominent disclosure + justification video for accessibility-based monitoring — prepare before review. |
| Remove dev endpoints / secrets | ❌ hardcoded dev secrets in `start-backend.bat` | Rotate `JWT_SECRET`, `INTERNAL_HMAC_SECRET`, set `VAULT_KEY`; point agents at production API. |
| FCM (for push) | 🟡 not configured | Add `google-services.json` + apply the Google Services plugin if push is wanted; polling fallback works meanwhile. |
| Pre-launch report | 🟡 | Let Play run it on the internal track; fix crashes it finds. |

## Windows desktop — what's required (current gaps)

| Requirement | Status | Action |
|---|---|---|
| Code-signing certificate | ❌ unsigned (SmartScreen warning) | Buy an OV/EV code-signing cert (EV = instant SmartScreen reputation); sign `OSRA.Agent.exe`. |
| Installer | ❌ raw exe folder | Package with MSIX or Inno Setup; add install/uninstall + autostart option. |
| HTTPS inspection root CA | 🟡 opt-in, self-signed | For production: provision the root via MDM/GPO; document removal steps. |
| Privacy/copies | 🟡 | Same privacy policy; disclose local proxy + content inspection when enabled. |

## Recommended path to publish

1. **Now:** run the internal Play track with the current APKs on 5–10 real devices
   (the physical-device matrix an emulator can't give: Samsung/Xiaomi/Oppo + Android 10–14).
2. Fix pre-launch-report crashes + OEM battery quirks.
3. Produce privacy policy + data-safety + rating + accessibility disclosure.
4. Generate the release keystore, switch signing, ship AAB to **closed testing** → production.
5. Windows: code-sign cert → MSIX installer → closed ring of tester PCs.

## What we validated on a real device (emulator)

Attempted 2026-09-17: Android Emulator 37.1.11 installed with the android-34 x86_64 Google
APIs image (AVD `osra-test` created), but boot is **blocked by hardware** — this PC's
firmware has **VT-x disabled** (`Virtualization Enabled In Firmware: No`), so no
hypervisor (Hyper-V/WHPX/AEHD) can run an x86_64 image. Enable "Intel Virtualization
Technology (VT-x)" in BIOS/UEFI to use local emulators. Until then, physical-device
validation is the path — exactly what the Play internal track provides.

---

## On-device smoke test — ANDROID EMULATOR (2026-09-19, first real device run)

Environment: Android 14 x86_64 emulator (AEHD hypervisor, after enabling VT-x in BIOS),
both OSRA APKs installed, paired LIVE against the running backend.

**Verified on device:**
- ✅ Both APKs install; OSRA branding on the pairing UI
- ✅ Full pairing round-trip through the real UI: 6-digit code → claim → device JWT →
  per-device HMAC secret stored (server confirmed the new Device row, `online`)
- ✅ LocationService runs as a foreground service (type=location); AccessibilityMonitorService
  enabled and bound
- ✅ **Real enforcement observed**: bedtime rule (21:00–07:00) blocked apps on-device with the
  "This app is blocked by your parent" screen
- ✅ Agent↔backend loop: command polling and the 60-second activity heartbeat return 200
  continuously over http (emulator host loopback)

**Found & fixed during the smoke (the point of device testing):**
- 🔧 **Child agent had no cleartext network-security config** — pairing failed on Android 9+
  with `CLEARTEXT communication not permitted` for every http:// LAN/dev server. Added
  `res/xml/network_security_config.xml` (test-build only, flagged) + APK rebuilt. The parent
  app had received this in an earlier fix pass; the child agent was missed.

**Blocked by the emulator environment (not the app):**
- Location pings: the app registers location monitoring (appops `MONITOR_LOCATION: allow`),
  but this emulator image never injects `geo fix` values into the fused provider
  (`last location=null` globally) — so no location callbacks fire to flush. Verify the
  location pipeline on a physical phone.
- Headless software rendering causes occasional SystemUI ANRs — cosmetic, emulator-only.
