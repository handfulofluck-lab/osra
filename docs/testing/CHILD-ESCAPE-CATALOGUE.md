# Child-escape test catalogue

Owner: Claude (architecture + testing). Schedule and who runs what: [`ESCAPE-TEST-SCHEDULE.md`](ESCAPE-TEST-SCHEDULE.md).
Script for the Android rows marked `adb`: [`../../scripts/hardware/android-escape-probe.sh`](../../scripts/hardware/android-escape-probe.sh).

## Why this exists

On 13 Nov 2026 the maintainer found two faults on the Flip4 in a few minutes, by doing what a child would do:

1. During a parent's **ring**, he pressed **Home**. The ring screen went away, the phone was usable, and the alarm
   kept sounding with no way to stop it on the phone (#734).
2. A second fault on the ring screen, filed privately (osra-security#17) until its fix merges.

Every device run before that day checked that the planned flow works: the parent sends a command and the phone
obeys. None of them played the child, who wants out. This catalogue is the child's side. Each row is one thing a
child (or a sibling, or a friend who "knows phones") tries, and what must still be true afterwards.

## Rules

- **Every gate screen gets the whole "standard escape set" (section 1), not only the rows written for it.** A new
  screen that blocks, locks, rings, asks for a PIN or hides something is added to section 2 as a new column of the
  matrix in the same PR that adds the screen.
- **A row passes only when the thing it protects is still true**: the gate is back on top within the time stated,
  the sound is still playing, the rule is still enforced, the parent got the alert. "The app didn't crash" is not
  a pass.
- **Results never go in this file or in any public issue or PR** (`AGENTS.md` §4). A row that lets the child
  through is a finding: it goes to `handfulofluck-lab/osra-security` as one issue, labelled `severity:*`, and the
  public repo gets only `osra-security#<n>` and a `beta-A blocker` issue that says which screen, not how.
- **Flip4 (personal phone, SIM):** never change its clock, date or time zone; never run
  `dpm remove-active-admin`; never guess, type or change the phone's own lock-screen PIN (unlocks are the
  maintainer's hand). Rows marked **no Flip4** run on an emulator or the second Android phone only.
- **Test iPhone:** no Airplane Mode (it breaks the driver), never change the Apple Account, date or time. Simulate
  offline from the Mac side. Rows marked **no iPhone** are expected-only until a second iPhone exists.
- Every run ends with the device as it was found (`AGENTS.md` §7, §9.3): no lock, ring, pause or block left on.
- A row's **Auto** column says how it is automated: `adb` (the escape probe), `instr` (Android instrumentation on
  the CI emulator), `jvm` (pure policy unit test), `xcui` (XCUITest via the Mac phone-driver or CI simulator),
  `flutter` (parent app integration/widget test), `api` (qa-probe against the server), `hand` (needs a human or a
  device-driving Claude: physical keys, reboot, SIM). `hand` rows are the first to look at for automation.

## 1. The standard escape set (every gate screen, every platform)

Run each of these against **each** screen in section 2. On Android a "gate screen" is the ring screen, the lock
overlay, the block screen, the bedtime/limit block, the paused-internet screen, the parent-PIN gate and the
tamper guard. On iPhone it is the shield (blocked app, bedtime, limit), the parent-PIN views and OSRA Kids' own
screens. On a computer it is the block/lock window.

| ID | The child tries | Must hold |
|---|---|---|
| E01 | **Home** (button, gesture, or the Flip's outer-screen gesture) | The gate is back on top within 2 s, every time, 10 presses in a row. Sound keeps playing. |
| E02 | **Back**, once and held | Nothing changes. Back is never a way out. |
| E03 | **Recents** (overview), then pick another app, then swipe the gate's card away | The gate comes back within 2 s. Swiping the card away does not end the gate or the ring. |
| E04 | **Split screen / pop-up view / freeform** from Recents, with the gate in one half | The gate refuses split or covers the whole screen; the other app is not usable. |
| E05 | **Picture-in-picture**: start a video in PiP, then trigger the gate | The PiP video is covered or closed; its sound does not keep playing over the gate. |
| E06 | **Notification shade** pulled down, then tap any notification | The tapped app does not stay on top; the gate returns within 2 s. |
| E07 | **Quick settings** from the shade: Airplane, Wi-Fi, mobile data, Do Not Disturb, volume, flashlight, screen recorder, Bixby/assistant tiles | The gate stays. Ring and alarm sound ignore DND. Toggles may change, but the gate and enforcement do not (offline rows: section 3). |
| E08 | **Volume keys** up/down/mute, held, during a ring | Ring volume does not drop. On a lock/block, volume is free (not a gate). |
| E09 | **Power key** once (screen off), then on again | The gate is still there after screen-on, over the lock screen. The ring keeps sounding with the screen off. |
| E10 | **Power key held** (power menu): Restart, Power off, Emergency mode | Restart is covered in section 3 (R rows). Emergency mode / SOS calling stays reachable (safety, never block it). |
| E11 | **Side key double press** (camera) or **Bixby/assistant** (side key held, "Hey Google") | Camera may open over the lock screen (it is a system secure camera), but the gate returns when it closes; assistant cannot open a blocked app. |
| E12 | **Wrong PIN**, five times; **empty PIN** then Continue; a **very long** PIN; letters pasted; Continue tapped twice fast | No crash, no hang, no pass. The process stays alive (`pidof` unchanged). Five wrong tries lock the gate for a while and alert the parent. |
| E13 | **Tap through**: tap the gate's buttons very fast, rotate during the tap, tap the button then press Home, tap Continue then Back | No path leads past the gate without the right PIN. |
| E14 | **Rotation / fold / unfold** while the gate is up (the Flip4 restarts activities on unfold; close it and use the cover screen) | The gate redraws on the screen in use, including the cover screen; nothing usable behind it; a ring keeps sounding through the restart. |
| E15 | **Accessibility shortcuts**: TalkBack, magnification, select-to-speak, the a11y button | Reading the gate is fine; none opens a way past it. |
| E16 | **Keyboard tricks**: a Bluetooth/USB keyboard (Alt+Tab, Meta key), keyboard's own settings or GIF/search panel inside the PIN field | No way out through the keyboard. The PIN field shows only the number pad. |
| E17 | **Incoming call / outgoing emergency call** during the gate | The call can be answered (safety). When it ends, the gate is back. Emergency dialler always reachable (S1). |
| E18 | **Crash the app** (any input that throws), or make it be killed (open many heavy apps, low memory) | The gate and the ring come back after the process restarts. A crash never equals "unlocked". |
| E19 | **Clear OSRA from memory** (Recents "Close all", Samsung "Device care → Clean now", a task-killer app) | Same as E18. |
| E20 | **Language / font size / display size / dark mode** changed in Settings while gated | Settings is guarded (tamper); if reached, the gate redraws and stays. |

## 2. Screen matrix: who gets which extra rows

### 2a. Android child (Play build `com.osratech.child`; Full build adds rows at 2b)

| ID | Screen / feature | Extra rows beyond section 1 | Must hold | Auto |
|---|---|---|---|---|
| AR01 | **Ring** (`RingActivity` + `Ringer`) | E01 Home, E03 Recents, E06 shade | Ring screen back on top within 2 s; sound never stops until PIN / parent `stop_ring` / cap. (Found 13 Nov: #734) | adb, instr |
| AR02 | Ring | E12 and E13 on the ring's PIN gate | Ring keeps sounding; process alive; only the right PIN stops it. | adb, jvm |
| AR03 | Ring | E18 force a process restart mid-ring (`am kill` from adb as a stand-in for a crash) | Ring resumes after restart until its original end time. | adb |
| AR04 | Ring | E08 volume keys, E07 DND "total silence", ringer on silent/vibrate | Alarm stream stays at max; the alarm usage gets through DND. | adb |
| AR05 | Ring | Unplugged headphones / Bluetooth speaker connected | Ring plays on the phone speaker, not only into a headset left in a bag. | hand |
| AR06 | Ring | Second `ring` while ringing; `stop_ring` while the PIN gate is open | One ring at a time; stop closes both screens; nothing left on screen. | adb, api |
| AL01 | **Lock** overlay (`LockActivity`) | Section 1 E01–E20 | Overlay back within 2 s. S1: emergency dialler always reachable. | adb (bypass probe rows 7–8) |
| AL02 | Lock | Lock arrives while the phone is offline, then online | Lock applied at the next poll; no window where the old state shows. | api, adb |
| AB01 | **Block screen** (blocked app, `BlockActivity`) | E01, E03, E04, E05, E06 | Blocked app never usable: covered within 1 s every time it comes to front. | adb, instr |
| AB02 | Block | Open the blocked app another way: its widget, a shortcut, a share sheet target, a deep link from the browser, "Open with", Google Assistant "open X", a Samsung Edge panel, a Secure Folder copy, a dual/clone app (Samsung Dual Messenger) | Every path ends in the block screen. Clone/Secure Folder copies are named in the app list and blockable. | adb (am start), hand (Edge, Secure Folder) |
| AB05 | Block | After a **ring or lock is dismissed**, reopen a still-blocked app from **Recents** (Ahmed's #731 row) | The blocked app is shielded again at once; dismissing one gate never lifts another. | adb |
| AB03 | Block | The blocked site/app inside another app: in-app browser, Chrome Custom Tab, WebView in a game, YouTube inside Google search | Web filter covers it (VPN/DNS), or a known gap is written in the guide. | hand |
| AB04 | Block | Install a second launcher, a different browser, or an APK from the Files app | Install needs the parent (Play: Family Link is out of scope, so: new app → alert + default rule applies). | adb (`pm install` test APK) |
| AT01 | **Bedtime / daily limit** block | Section 1 + wait across the bedtime start while a blocked app is open | The app is covered at the minute bedtime starts, not at the next app switch. | adb |
| AT02 | Bedtime / limit | Clock and time zone changes (manual time, travel time zone) — **no Flip4** | Limits use server time or monotonic time; changing the clock does not end bedtime or reset the limit. Parent alerted. | instr (emulator only) |
| AT03 | Bedtime / limit | Use the app in split screen / PiP to keep it alive past the limit | As AB01. | adb |
| AP01 | **Pause internet** | Section 1; Wi-Fi off and mobile data on, or the reverse; another VPN app; Private DNS set by hand; a hotspot from a friend's phone | Pause holds on every network. Turning OSRA's VPN off is a tamper event (bypass probe row). | adb, hand |
| AG01 | **Parent-PIN gate** (`TamperGuardActivity`, every reason: settings, re-pair, remove, ring) | E12, E13, E16, E18 | Wrong/empty/garbage never passes; no crash; 5 tries → lockout + alert. | adb, jvm, instr |
| AG02 | PIN gate | Brute force: 4-digit PINs tried over hours, restarting the app between tries | The attempt counter survives restarts; back-off grows. | instr |
| AS01 | **Tamper guard** (Settings screens that remove protection) | Reach them by search in Settings, by a shortcut widget, by Samsung "Routines", by "Modes", by `Settings → Apps → OSRA → Force stop / Clear data / Uninstall`, by the long-press app-icon menu "App info" | Every path is covered by the PIN gate before the button can be tapped. | adb (bypass probe rows 1, 2, 4, 5, 10) |
| AS02 | Tamper guard | Turn off OSRA's accessibility service, overlay permission, battery "unrestricted", notification permission, location | Each one is either guarded or reported to the parent within the stated time (status screen + alert). | adb |
| AS03 | Tamper guard | **Safe mode** (power-menu long-press "Power off" → Safe mode) — boots with no third-party apps | Parent alerted that the device went silent; on the next normal boot OSRA restarts and reports the gap. Documented as a known OS limit. | hand |
| AS04 | Tamper guard | **Reboot**, and reboot then do nothing (no unlock) | Agent starts at boot (direct-boot-aware where possible); a lock/ring/bedtime in force before the reboot is in force after it. | hand (reboot on the Flip4 needs the maintainer's unlock afterwards: book it) |
| AS05 | Tamper guard | **Uninstall** from the launcher, from Play Store, from Settings, by `adb` (a child with developer options) | Launcher/Play/Settings paths hit the PIN gate. Developer options and USB debugging on → alert (adb is a known OS limit). | adb (bypass probe row 1) |
| AS06 | Tamper guard | **Clear data / clear cache / force stop** | PIN gate; if reached anyway, the server notices the silent device (bypass probe row 3) and the agent re-claims its pairing. | adb |
| AS07 | Tamper guard | **Factory reset** from Settings or recovery | Settings path guarded; recovery reset is a known OS limit, the parent sees "device silent" then "device removed". | hand (never on the Flip4) |
| AS08 | Tamper guard | **New user / guest mode / Secure Folder / second space** | Switching user is guarded or reported; OSRA is not present in the other profile, so the parent is told. | hand |
| AS09 | Tamper guard | **SIM swap / remove SIM**, and **eSIM** added | Reported to the parent; enforcement unchanged. | hand (Flip4 SIM: maintainer only) |
| AO01 | **Offline** | Airplane mode during a lock, ring, bedtime, block | On-device enforcement keeps working offline; the parent sees "last seen" freeze and a "stopped checking in" alert. Commands queued offline land on reconnect. | adb (`svc wifi/data`), api |
| AO02 | Offline | Battery saver / Ultra power saving / "Put app to sleep" / Low battery (≤5 %) | Enforcement and the ring survive battery saver; at critical battery the parent is told. | adb (`dumpsys battery set level 5`, then `reset`) |
| AN01 | **Notifications** | Long-press OSRA's ongoing notification → turn off notifications for OSRA, or snooze it | Turning off the channel does not stop enforcement; it is reported to the parent. | adb |
| AQ01 | **SOS** (child's own, tile + `SosActivity`) | Pocket-dial: 10 fast taps; the child cancels; tile used while locked | Countdown cannot be skipped; cancel works; SOS works from a locked overlay (safety). | adb, jvm |
| AY01 | **Pairing / onboarding** | Child opens the agent and taps "unpair", "re-pair", "server" field, or deep links into setup screens | Every path needs the parent PIN or the server's authorised unpair. | adb |

### 2b. Android Full build (sideloaded, `full` flavour) — extra rows

| ID | Feature | The child tries | Must hold | Auto |
|---|---|---|---|---|
| AF01 | Notification capture | Turn off OSRA's notification access | Guarded or reported. | adb |
| AF02 | Call log / SMS | Use a second messenger, delete the log, use Wi-Fi calling from another app | Known limits written in the guide; deleting the log after capture does not delete the server copy. | hand |
| AF03 | Full-build update | Install an older OSRA APK over the new one | Downgrade refused (signature + version check). | adb |

### 2c. Parent app (Android and iPhone, Flutter) — the child holds the parent's phone

| ID | Feature | The child tries | Must hold | Auto |
|---|---|---|---|---|
| PA01 | **App lock** (#742) | Open the parent app on the parent's unlocked phone and loosen a rule, unlink a device, pause protection, unblock an app or stop a ring | Each of these asks for the parent's fingerprint, Face ID or device PIN first (maintainer's decision 13 Nov, #742). Cancel, a failed scan, Back, Home and backgrounding the prompt never let the change through; the change is not sent before the check passes. | flutter, hand |
| PA02 | Session | Stay signed in for weeks; sign out on one phone; change password elsewhere | Refresh rotation; a password change ends other sessions. | api, flutter |
| PA03 | Destructive actions | Remove the child's device, delete the account, turn off monitoring | Re-auth dialog (password or MFA) every time; never one tap. | flutter |
| PA04 | MFA | Wrong codes, replayed code, recovery code used twice, MFA reset without the witness | All refused, attempts limited and logged. | api (qa-probe), flutter |
| PA05 | Pairing QR | Screenshot the parent's pairing QR and use it later, or twice | Code is single-use and short-lived. | api |
| PA06 | Commands | Double-tap ring/stop, lock/unlock fast, send while offline | Exactly the last intent wins on the child; history shows each command once. | api, flutter |
| PA07 | Notifications | Read alert previews on the parent's lock screen | Previews carry no child content (data-only push). | hand |

### 2d. OSRA Kids on iPhone (Family Controls `.child`)

The iPhone removal rows already written in [`../QA/IOS-REMOVAL-ATTEMPTS.md`](../QA/IOS-REMOVAL-ATTEMPTS.md)
(R1–R13, Ahmed) stay the source for removal. This table adds the escape rows for the shield and OSRA Kids' own
screens.

| ID | Screen / feature | The child tries | Must hold | Auto |
|---|---|---|---|---|
| KS01 | **Shield** (blocked app) | Section 1 E01 Home/swipe-up, E03 app switcher, E06 Notification Centre, E07 Control Centre | The blocked app never shows content. | xcui |
| KS02 | Shield | Open the blocked app another way: Spotlight, Siri ("open X"), a widget, a Share sheet, a link from Messages/Safari, App Library, a Shortcut, the App Store "Open" button | Every path hits the shield. | xcui, hand (Siri) |
| KS03 | Shield | Shield buttons: "Ask parent", "Close" tapped fast, many times | No path opens the app; "Ask parent" sends one request (not 20). | xcui |
| KS04 | Shield | Web version of the blocked app in Safari / in-app browser | Covered by the web filter or written as a known gap. | hand |
| KS05 | Bedtime / limit | Clock change (blocked by Screen Time on a child account), time zone travel — **no iPhone** clock change | Expected-only on the test iPhone. | — |
| KS06 | Bedtime / limit | Reinstall the app (delete is refused: IOS-REMOVAL R1), offload (R2) | Shield and limits stay. | hand |
| KP01 | **Parent PIN views** (`ParentPinViews`) | E12 empty/wrong/long/pasted PIN, E13 fast taps, backgrounding the app mid-entry | No crash, no pass; attempt limit survives a relaunch. | xcui, Swift unit |
| KR01 | **Ring / locate** on iPhone | Silent switch on, Focus mode, volume down, swipe the notification away | Behaviour written per platform limit (iOS cannot hold the screen); critical-alert entitlement decides whether the sound gets through. | hand |
| KO01 | Offline | Wi-Fi + data off from the Mac side (never Airplane Mode on the test iPhone) | Shields hold offline; parent sees "stopped checking in". | xcui + server |
| KX01 | Extensions | Force-quit OSRA Kids from the app switcher; low power mode; Background App Refresh off | Shields stay (extensions run without the app); parent told if reports stop. | xcui, hand |

### 2e. Windows (`apps/agent-desktop`) — staging Windows Server 2025 test machine, then a clean Windows 11 run

The child uses a **standard (non-admin) Windows account**; the parent owns the admin account. Rows that need a
separate disk, a live USB or BIOS access are run on the test VM's snapshot only, never on the maintainer's PC.

| ID | The child tries | Must hold | Auto |
|---|---|---|---|
| WN01 | **Alt+Tab, Win key, Win+Tab (Task View), Win+D (desktop), a second virtual desktop (Win+Ctrl+D)** over the block or lock window | Block/lock window back on top within 2 s on every desktop and every monitor. | UI automation (FlaUI / WinAppDriver) |
| WN02 | **Ctrl+Shift+Esc / Ctrl+Alt+Del → Task Manager → End task / End process tree** on OSRA's tray app and its process | A standard user cannot end the service (it runs as SYSTEM); the tray app is restarted by the service; the parent gets an alert. | script (`taskkill` as the child user) |
| WN03 | **Services**: `services.msc` stop/disable, `sc stop`, `sc config start= disabled` | Refused for a standard user. If done from an admin account, the parent is alerted at the next check-in gap. | script |
| WN04 | **Safe Mode** (Shift+Restart → Troubleshoot → Startup settings) and Safe Mode with Networking | Safe Mode needs admin on a managed machine, or the service is registered to run in Safe Mode; otherwise the parent sees "device silent" and the boot reason. | hand (test VM) |
| WN05 | **A new local account**, a Microsoft account sign-in, the Guest/other user, "Switch user" | Creating accounts needs admin. A user with no OSRA session is reported to the parent (per-machine enforcement where possible). | script (`net user` as the child) |
| WN06 | **The system clock and time zone** (Settings → Time, `Set-Date`, `w32tm`), and the BIOS clock | Standard users cannot change the clock; limits and bedtime use server time or a monotonic counter, so a changed clock ends nothing. | script (test VM only) |
| WN07 | **Uninstall** from Settings → Apps, Control Panel, the MSI with `msiexec /x`, deleting `Program Files\OSRA`, deleting the data folder | Needs admin plus the parent PIN; files are ACL-protected; the parent is alerted. | script |
| WN08 | **Startup**: Task Manager → Startup apps → disable, `shell:startup`, Run keys, Task Scheduler | The service, not a startup entry, keeps OSRA running; disabling the tray entry is restored or reported. | script |
| WN09 | **hosts file, DNS, proxy**: edit `C:\Windows\System32\drivers\etc\hosts`, set DNS by hand, DNS-over-HTTPS in the browser, a system proxy, `netsh winhttp reset proxy` | Filter holds (hosts/DNS edits need admin); DoH in a browser is caught by policy or written as a known gap. | script |
| WN10 | **VPN**: a VPN app, Windows' built-in VPN, Tor Browser, a browser VPN extension | Installing needs admin; a VPN that runs is detected and reported, or written as a known gap. | script + hand |
| WN11 | **Portable apps and second browsers**: a portable Firefox/Chrome from a USB stick or the Downloads folder, a game that needs no install, the Microsoft Store | Blocked by name/hash/publisher, or caught by the web filter; a new executable is reported. | script |
| WN12 | **Boot from USB** / Windows PE / a Linux live USB, or remove the disk | Known limit, documented; BitLocker + BIOS password recommended in the guide; the parent sees "device silent". | hand (test VM: attach an ISO) |
| WN13 | **Firewall**: block OSRA in Windows Defender Firewall, or pull the network cable | Rule changes need admin; offline enforcement holds; "stopped checking in" alert. | script |
| WN14 | **PIN dialogs** (`PairingDialog`, `ParentPinPolicy`): empty, wrong ×5, very long, pasted, Esc / Alt+F4 / closing the window | No crash, no pass; the lockout survives a restart; closing the dialog is never "yes". | unit + UI automation |
| WN15 | **SOS hotkey** (`SosHotkey`) pressed repeatedly, or remapped by another app | One SOS per press within the guard window; reported if the hotkey can't be registered. | unit |
| WN16 | **Sleep, hibernate, lid close, fast startup** during a lock or bedtime | Restriction in force at wake. | hand |

### 2f. macOS (Swift agent, ADR-0036) — the MacBook test bed

The child uses a **standard macOS account**; the parent owns the admin account.

| ID | The child tries | Must hold | Auto |
|---|---|---|---|
| MC01 | **Cmd+Tab, Mission Control, a new Space, Hot Corners, Cmd+H / Cmd+M, full-screen another app** over the block or lock window | Block/lock window back on top within 2 s on every Space and display. | XCUITest (macOS) |
| MC02 | **Activity Monitor → Quit / Force Quit**, Option+Cmd+Esc, `kill`/`killall` in Terminal | The root daemon (SMAppService) cannot be ended by a standard user; the UI agent restarts; the parent is alerted. | script |
| MC03 | **Login items**: System Settings → General → Login Items → turn OSRA off; delete the LaunchAgent/Daemon plist | Background items need admin to change; removal is reported. | script |
| MC04 | **Content filter / system extension**: System Settings → Network → Filters → disable; Privacy & Security → remove the extension | Needs admin; disabling is reported within one check-in. | hand |
| MC05 | **Configuration profiles**: System Settings → Privacy & Security → Profiles → remove | Needs admin; reported. | hand |
| MC06 | **Safe Mode** (hold Shift / power button on Apple silicon) and **Recovery** (csrutil, reset password) | Known limit for third-party agents; parent sees "device silent"; the guide recommends a firmware password where available. | hand (never without the maintainer) |
| MC07 | **A new user account**, Guest user, fast user switching | Needs admin; a session without the agent is reported. | script |
| MC08 | **The clock and time zone** (System Settings → Date & Time, `sudo date`) | Needs admin; limits use server/monotonic time. | expected-only on the MacBook (never change its clock) |
| MC09 | **Uninstall**: drag the app to the Bin, delete `/Library/...` files, an uninstaller app | The app bundle alone is not the agent; deleting it is reported; the daemon stays or the parent is alerted. | script |
| MC10 | **hosts, DNS, proxy, VPN, iCloud Private Relay, a second browser, a portable app from a USB disk** | As WN09–WN11. | script + hand |
| MC11 | **Terminal** as a standard user: `launchctl bootout`, `pkill`, editing preferences plists | Refused, or reported. | script |
| MC12 | **PIN views** (shared Swift package): empty, wrong ×5, long, pasted, closing the window | As KP01. | Swift unit + XCUITest |
| MC13 | **Sleep, lid close, external display only (clamshell)** during a lock or bedtime | Restriction in force at wake and on the external display. | hand |

## 3. Restart and power rows (all platforms)

| ID | The child tries | Must hold |
|---|---|---|
| R01 | Reboot during a ring | After boot (and unlock), the ring resumes until its end time, or the parent sees "ring interrupted by restart". |
| R02 | Reboot during a lock / bedtime / pause | Restriction in force at the first screen after boot. |
| R03 | Power off for an hour | Parent alerted "device silent"; queued commands land at boot. |
| R04 | Battery dies during a ring | Parent sees "device silent" with the last battery level. |

## 4. How a row becomes a test

1. **Hand run first** on the device (the schedule says who and when), with screenshots and the logcat/XCUITest
   output kept in the run folder.
2. If the row can be scripted, the scripted version goes into `scripts/hardware/android-escape-probe.sh` (Android
   keys and shell), an instrumentation test (CI emulator), a JVM test (pure policy), an XCUITest (iPhone), or a
   Flutter test (parent app). The row's **Auto** column then names the file.
3. Every release candidate runs the whole catalogue: scripted rows by CI and by the device threads, `hand` rows by
   the device threads, in the slots in the schedule.
4. A failed row is a `beta-A blocker` issue (and, if it lets the child through, an osra-security issue). The fix PR
   adds the test that fails without it.

## 5. Adding rows

Anyone may add a row: a member who thinks of a new escape adds it here in a docs PR (R1) or comments it on the
schedule issue, and it joins the next run. Each release candidate starts with 30 minutes where each AI family
writes down escapes it thinks of from reading the code, before anyone looks at this list, so the list doesn't
only test what its author already thought of.
