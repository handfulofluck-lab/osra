# ADR-0010 — Android tamper protection: Device Admin tiers, parent PIN, screen guard

**Status:** Accepted · 2026-10-17 · Phase 1.1/1.2 of the KCL plan (`docs/QA/KCL-2026-10-16/`)

## Context

The assessment's first finding about the Android agent: a motivated child removes it in seconds.
There was no `DeviceAdminReceiver`, so `adb uninstall`, Settings › Uninstall and the launcher's
long-press all worked; the launcher's **Re-pair** button cleared the pairing with no check at all
(`PairingActivity`); and nothing told the parent. Every other feature — lock, limits, SOS — is
optional for the child while that is true. Acceptance for 1.1/1.2: *`adb uninstall` and Settings ›
Uninstall both fail without the PIN; alert within 60 s if admin is revoked; no path from the child
UI clears pairing.*

Platform facts that fix the design: a plain Device Admin cannot be uninstalled by the package manager
(`DELETE_FAILED_DEVICE_POLICY_MANAGER`) until it is deactivated, and deactivation goes through one
Settings screen; only a **device owner** gets `setUninstallBlocked`; an accessibility service can see
every foreground window's text and can start an activity over it (the agent already does this for
app blocking); the OS offers no hook to put a PIN prompt *inside* its deactivate-admin dialog.

## Decision

1. **Three tiers, decided by what the OS granted** (`TamperPolicy.tierOf`): `NONE` (no admin:
   alert-only), `ADMIN` (active Device Admin: uninstall needs admin cleared first, which the guard
   gates with the PIN, and `lockNow` works), `OWNER` (device owner via `dpm set-device-owner` or EMM:
   `setUninstallBlocked` and lock-task). The agent runs on whichever tier it has and shows it on the
   status screen; the parent is never lied to about the tier.
2. **A parent PIN is set at pairing** (`ParentPin`, PBKDF2-HMAC-SHA256, 120 000 iterations, 16-byte
   salt, constant-time verify, 4–8 digits, weak PINs refused), stored only as its hash in
   `EncryptedSharedPreferences` (`SecureStore`, AES-256-GCM under the keystore). Once a PIN exists
   every protection-removal action needs it: Re-pair, Remove protection, and the OS screens below.
   Before a PIN exists nothing is gated — pairing sets one, so that window is the setup screen only,
   and a family can never be locked out of their own Settings by a half-configured agent.
3. **The accessibility service guards the three OS screens** that strip protection — the Settings
   deactivate-admin confirmation, the package installer's uninstall dialog and App info for our
   package (`TamperScreenPolicy`, a pure classifier: system package + the agent named on screen + a
   removal verb). It presses Back and raises `TamperGuardActivity`, a full-screen PIN gate. A correct
   PIN grants a two-minute grace window in which the guard stands down so the parent can finish; a
   wrong PIN five times, or Back, returns to the launcher. Each trigger also sends the parent a
   `tamper` alert (`protection_screen_opened`).
4. **Admin removal always reaches the parent within seconds.** `FamilyShieldDeviceAdmin.onDisabled`
   sets a persisted flag and enqueues an expedited `TamperAlertWorker` (`device_admin_removed`); the
   60-second loop in `LocationService` drains the flag and also alerts on any observed tier drop to
   `NONE`, so a process kill between the two cannot lose it. A removal the parent performed through
   the app with the PIN is marked sanctioned for one minute and raises no alert.
5. **Remote lock uses the real thing when it can.** `lock` calls `DevicePolicyManager.lockNow()` on
   `ADMIN`/`OWNER` and still shows the overlay so the child sees why.

## Consequences

- `adb uninstall com.familyshield.agent` → `DELETE_FAILED_DEVICE_POLICY_MANAGER` on `ADMIN`;
  Settings › Uninstall is greyed until admin is deactivated, and deactivating meets the PIN gate.
- The guard depends on the accessibility service being on; if the child turns that off first, the
  existing accessibility-off tamper alert (#19) fires, and admin itself still blocks the uninstall.
  Force-stop from App info remains possible on `ADMIN` (the OS allows it). **Measured by the 1.9
  probe (2026-10-17, Flip4 / Android 16): a force-stopped app is kept in Android's *stopped state* —
  no broadcast, job, alarm or accessibility rebinding reaches it until it is launched again**, so
  "the boot receiver brings it back" is only true after the next launch or boot. What holds the line
  on `ADMIN`: the App-info screen (where Force stop and Clear data live) is PIN-gated by the
  accessibility guard, and the adb routes (`am force-stop`, `pm clear` — which wipes the pairing
  even with admin active) are answered server-side by the `device_silent` alert (an active device
  unseen for 30 min). `OWNER` is the tier that blocks both at the OS.
- OEM Settings wording differs; the classifier matches generic verbs plus our labels and is covered by
  JVM tests for AOSP/Google/Samsung phrasing. A screen it misses is a finding, not a crash: the device
  stays on the same tier and admin still blocks the uninstall.
- The PIN hash lives in the keystore-backed store; if that store cannot open (rare OEM keystore
  faults) `SecureStore` falls back to plain prefs — a salted PBKDF2 hash, still not the PIN.
- **Not done here:** lock-task mode and the device-owner provisioning flow (1.3), a parent-app
  surface to change or reset the PIN (Phase 3 — until then the parent re-pairs with the PIN), and
  the ten-bypass device probe (1.9) that will measure all of this on hardware before every merge.

## Alternatives rejected

- *Device owner only* — gives the strongest block but needs `adb`/EMM provisioning of a factory-reset
  device; parents sideloading the Full build will not do that. It stays as the top tier, not the floor.
- *Hide from the launcher / fake an app name* — detection-evading tricks violate Play policy and the
  "stalkerware" line in `isMonitoringTool`; the agent is honest about what it is and relies on the
  PIN, not disguise.
- *PIN inside the OS dialog* — impossible; hence the accessibility guard in front of it.
