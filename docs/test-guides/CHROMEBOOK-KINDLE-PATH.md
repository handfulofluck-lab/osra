# Chromebook & Kindle Fire — Best-Effort Path (Feature #26)

> Honest status: OSRA has **no native ChromeOS or Fire OS build**. Both platforms
> are Android-derived, so the supported path is the existing Android child agent
> (`dist/OSRA-ChildAgent.apk`, minSdk 26 / targetSdk 34). This document covers
> what works, what degrades, and exactly how a tester validates each device. No code was
> written for this feature — the Android agent's polling-first design (no hard FCM
> dependency) is what makes sideloading viable at all.

## A. Chromebook (ChromeOS)

ChromeOS runs Android apps inside a sealed container with the Play Store, so the child
APK installs mostly like on a phone.

**What works**
- App install from `dist/OSRA-ChildAgent.apk` (Play Store if published, else
  sideload — steps below).
- **Accessibility enforcement** (app blocking, social-capture hooks, anti-tamper) — the
  Android AccessibilityService runs normally in the ChromeOS container.
- Screen-time limits, routines, bonus/wind-down commands (they're in-app logic).
- Command delivery — the agent's HTTP polling (`CommandPollWorker`/`WorkScheduler`) works
  over Wi-Fi identically.

**What is partial (NOTE)**
- **Chrome browser is not covered.** On ChromeOS the browser is the *native* Chrome app,
  not the Android Chrome APK, so accessibility events and web filtering never see it.
  Only Android apps' web views and any installed Android browser are filtered. Family
  Shield's web-level protection on Chromebook therefore needs **ChromeOS-managed Google
  Family Link** as a companion (link the child's Google account there for browsing).
- **Location is network-based.** Most Chromebooks lack GPS; location reports fall back to
  Wi-Fi/cell triangulation and can be coarse or stale.
- **App-level filtering only applies to Android apps.** Native ChromeOS apps (Linux Crostini
  apps, PWAs installed by Chrome) are outside the Android container entirely.

**Tester steps (Chromebook)**
1. Update ChromeOS; sign in. Sideload path: `Settings ▸ Apps ▸ Google Play Store ▸ Manage
   Android preferences ▸ Security ▸ Unknown sources` (on school-managed devices this is
   greyed out — use `adb install` in developer mode instead, or Play Store distribution).
2. Install `OSRA-ChildAgent.apk` (Files app → tap the APK, or
   `adb install OSRA-ChildAgent.apk`).
3. Open the agent → enter the pairing code from the parent app → confirm the
   "protection active" notice appears.
4. System Settings → Accessibility → enable **OSRA** (switch ON).
5. Grant location (All the time for geofences), usage-access, notifications, and
   "install unknown apps" when prompted (needed for install-approval, Feature #8).
6. Verify: parent app blocks an Android app → child sees the block screen within ~60 s
   (poll interval); `locate_now` returns a Wi-Fi-based position; pause-internet overlay
   shows over Android apps.
7. Verify the companion: child's Chrome browsing is managed via Google Family Link
   (OSRA does not intercept it on ChromeOS).

## B. Kindle Fire (Fire OS)

Fire OS 7/8 are Android 9/11 forks without Google Mobile Services. The APK sideloads
cleanly because the agent never *requires* FCM.

**What works**
- Sideloading `dist/OSRA-ChildAgent.apk` — the Amazon Appstore is **not** needed.
- All in-agent enforcement: accessibility app blocking, screen time, routines, SOS tile,
  install approval, tamper/VPN checks.
- **Command delivery via HTTP polling.** No Google Play services means **no FCM** on Fire
  OS — commands arrive on the agent's existing periodic `CommandPollWorker` schedule
  rather than instantly. (NOTE: this is a latency trade-off, not a functional gap; the
  polling path is already the production default on all devices.)

**Fire OS 7/8 quirks (NOTE)**
- Aggressive background kill: Fire tablets suspend apps hard. The agent requests battery
  optimisation exemption at pairing — the tester must accept it, or polling and SOS stop
  when the screen is off.
- Notifications render through Amazon's channel system; heads-up alerts are less
  prominent than on stock Android — check the notification shade in tests.
- No Google Play services also means **no SafetyNet/Play-integrity checks** and no FCM
  fallback: if the API URL is unreachable, queued commands simply wait for the next poll.
- Silk is the native browser; the agent's web filter covers Android WebView/browser apps
  only — the Silk browser itself is **not** filtered (same limitation class as ChromeOS).

**Tester steps (Kindle Fire)**
1. `Settings ▸ Security & Privacy ▸ Apps from Unknown Sources` → allow the file manager
   (or use `adb install` with USB debugging enabled under `Device Options`).
2. Copy `OSRA-ChildAgent.apk` to the tablet and install it.
3. Open the agent, pair with the parent app's code, accept **every** permission prompt —
   especially **Disable battery optimisation** (critical on Fire OS) and Accessibility.
4. Verify enforcement: block an app from the parent app; confirm the shield appears on the
   next poll cycle (≤ 60 s typical).
5. Verify persistence: lock the screen for 10 minutes, then send `locate_now` — the reply
   must still arrive (proves the polling worker survived Fire OS's background kill).
6. Verify SOS via the quick-settings tile.

## Honest bottom line

- **Chromebook**: solid for app/time management of Android apps; web browsing needs
  Google Family Link as a companion; location is coarse.
- **Kindle Fire**: fully usable as an Android child device with polling-based command
  latency and mandatory battery-exemption; Silk browsing unfiltered.
- Neither is a first-class native port; both are supported as **sideloaded Android
  deployments** and should be labelled exactly that way in tester materials.
