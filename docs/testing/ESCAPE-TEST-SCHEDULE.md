# Child-escape testing: who attacks what, and when

Owner: Claude (architecture + testing). The rows are in [`CHILD-ESCAPE-CATALOGUE.md`](CHILD-ESCAPE-CATALOGUE.md).
Times are UTC, with Dubai time (UTC+4) in brackets. The maintainer can move any slot; the device owner then tells
this file's owner, who updates it.

## 1. The rule: two AI families on every feature

Every catalogue row is attacked by **at least two different AI model families** (`AGENTS.md` §6.6 lists them):
one family runs it by hand on the real device, another writes the automated version from the code and the
catalogue without seeing the hand result first. A third family reads the gate code each release candidate looking
for escapes nobody listed (catalogue §5).

| Client | Hand run on the device (family) | Automated attack written by (family) | Code-read attack each RC (family) |
|---|---|---|---|
| Android child (Play + Full) | PC Claude, "Team collaboration sync" thread, on the Flip4 (Anthropic) | Kimi: instrumentation tests on a CI emulator + `android-escape-probe.sh` rows (DeepSeek) | K31 (Moonshot) |
| Android parent app | PC Claude on the Flip4 (Anthropic) | K31: Flutter tests for PA rows (Moonshot) | Kimi (DeepSeek) |
| iPhone parent app | Mac Claude, "Set up MacBook and iPhone test bed" thread, on the test iPhone (Anthropic) | K31: the same Flutter tests run on iOS (Moonshot) | Kimi (DeepSeek) |
| OSRA Kids (iPhone) | Mac Claude on the test iPhone (Anthropic); Ahmed's removal rows R1–R13 | K31-Mac: XCUITest escape suite for KS/KP rows, run by the Mac phone-driver and the CI simulator (Moonshot) | Kimi (DeepSeek) |
| Windows | PC Claude on the staging Windows Server 2025 VM, then one clean Windows 11 run (Anthropic) | K31: PowerShell / UI-automation scripts for WN rows (Moonshot) | Kimi (DeepSeek) |
| macOS | Mac Claude on the MacBook (Anthropic) | Kimi: scripts for MC rows (DeepSeek; never K31-Mac, who builds the Mac client) | K31 (Moonshot) |
| Server side of every row (alerts, commands, "device silent") | Claude, `qa-probe` on staging (Anthropic) | Kimi / K31, whoever did not write the endpoint | Ahmed: security review (Anthropic, human) |

Claude (this catalogue's owner) does not hold a device slot. It reviews every automated attack against its row,
collects results, files findings and sends the daily summary (§4). Fable reviews a gate-screen fix as the R3
security key when it is one.

## 2. Device time (no double booking)

| Device | Owner of the device | Escape slot | Notes |
|---|---|---|---|
| **Flip4** (`R5CW116Y6GF`, the maintainer's personal phone, SIM) | Team collaboration sync (PC Claude), lease `phone-claim.ps1` | **Daily 14:00–15:00 (18:00–19:00 Dubai)**, plus within 24 h of each new child APK | Ring rows play the alarm at full volume, so they run in this slot only. Rows that need a reboot, the power key on the secure lock screen, or the SIM are batched as **HAND-KARIM** for one 15-minute slot the maintainer picks. Never a clock, `dpm` or lock-screen PIN change. |
| **Test iPhone 13** | Mac test bed (Mac Claude) | **Nightly 20:00–22:00 (00:00–02:00 Dubai)**, plus each new Kids or parent build | Build uploads and PR device rows take priority (about 15 minutes; the Mac thread says when). Reboot and Airplane Mode rows are HAND-KARIM (he types the passcode). |
| **MacBook M2** | Mac test bed (Mac Claude) | **22:00–23:00 (02:00–03:00 Dubai)** once a macOS agent build exists | Never change its clock; Recovery and Safe Mode rows only with the maintainer. |
| **Windows Server 2025 VM** (staging, `osra-windows-test`) | Team collaboration sync (PC Claude) | **Daily 15:00–16:00 (19:00–20:00 Dubai)** once a Windows build exists (W1, #623) | Start the instance for the slot and stop it after (cost rule). Snapshot the clean state first; USB-boot and Safe-Mode rows run on a snapshot. |
| **CI Android emulator** | Kimi (job owner) | Every PR that touches `apps/child-android`, and nightly **02:00 (06:00 Dubai)** | Clock and time-zone rows (AT02) run only here. |
| **CI iOS simulator** | K31-Mac (job owner) | Every PR that touches `apps/child-ios`, and nightly **03:00 (07:00 Dubai)** | Shield rows need a device; the simulator runs PIN-view and app-screen rows. |

## 3. Release candidates

1. A release candidate is any build headed for testers outside the team (a Play internal-test APK, a TestFlight
   build, a Windows or Mac installer).
2. Within 24 hours of the build, every row of that client's sections runs: automated rows in CI and on the device,
   hand rows in the next slot.
3. The client's release security gate (#630–#637) is not asked for until that client's escape run has no open
   failure. A failure is a `beta-A blocker` issue (and an osra-security issue when it lets the child through).
4. The fix PR adds the automated row that fails without it, and the device owner re-runs the hand row on the fixed
   build.

## 4. Reporting

- Results per run: the device threads write one PASS / FAIL / NOT RUN line per row at the top of their results
  file in the project's shared folder (`team-sync/<client>-child-escape/results.md`), with the build, time and
  row ID. Bypass details only in `osra-security`.
- **Daily summary to the maintainer, 05:00 (09:00 Dubai)**: one line per client: rows run, passed, failed, not
  run, and the open blockers with their issue numbers. It complements Team collaboration sync's 15-minute status;
  it does not repeat it.

## 5. Tonight's start (13 Nov 2026)

- iPhone: the Mac test bed started the OSRA Kids escape run on build 8 at 20:37, and runs nightly from now on.
- Flip4: #734 (Home escape during a ring) and osra-security#17 are open, with Kimi/Ahmed. The Flip4 escape slot
  starts tomorrow 14:00 with the probe, then re-runs AR01/AR02 on the fixed APK.
- Windows and Mac: the rows are written; runs start when each client has a build.
