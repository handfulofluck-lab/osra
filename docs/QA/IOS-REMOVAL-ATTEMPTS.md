# OSRA Kids on iPhone: what a child might try, and what should happen (SC-5.5)

Owner: Ahmed (security + testing). Run by: the Mac test bed, pair C (#665). Issue: #669 part 1.

This is the iPhone counterpart of the Android child's ten-row bypass probe. Each row is one thing a child could
try on an iPhone running OSRA Kids under FamilyControls `.child` authorisation (the child's Apple Account is in
the parent's Family Sharing). For each row it gives what should happen and how to observe it from the Mac or the
server.

**Rules for the run:**
- Use the staging test family only: no real family data, not the production account.
- Stop at every confirmation dialog and tap **Cancel**, unless the row says otherwise.
- Rows marked **NOT RUN** change the Apple Account, the date or time, or need the device passcode. Record them as
  `NOT RUN: <reason>` with the expected result. Don't attempt them on the test bed.
- **Server view** below means the child device in the parent's device list: its `lastSeen`, its capability report
  (`features.screen_time`, `features.location`, `grants.location`, `grants.family_controls`), and any alert stored for the family.

| # | The child tries | What should happen | How to observe | Run? |
|---|---|---|---|---|
| R1 | Delete OSRA Kids from the Home Screen (long-press, **Remove App**, **Delete App**) | iOS refuses with "Uninstall Not Allowed": deleting needs parent or guardian approval. | Dialog on screen (screenshot). The device stays paired in the server view. | RUN, then Cancel. Passed on #634 D5 (osra-security#11). |
| R2 | Offload the app (Settings → General → iPhone Storage → OSRA Kids → **Offload App**) | Refused like R1, or behind the same parent approval. If iOS offloads it anyway, shields stay (ManagedSettings) and the app comes back with its data on reinstall. | Dialog on screen. If offloaded: tap the icon to reinstall, then check the status screen still shows paired. | RUN to the confirmation. Record what iOS shows. |
| R3 | Turn off OSRA Kids under Settings → Screen Time → **Apps With Screen Time Access** | "Parental Approval Required" (the parent's Apple Account). The switch stays on. | Dialog on screen. `features.screen_time` stays `ready` and `grants.family_controls` stays `granted` in the server view. | RUN, then close. Passed on #634 D5. |
| R4 | Turn Screen Time off, or change the Screen Time passcode | Both ask for the parent's Screen Time passcode, which the child doesn't have. | Passcode prompt on screen. | RUN to the prompt, then Cancel. |
| R5 | Change Content & Privacy Restrictions (for example allow Deleting Apps) | Asks for the parent's Screen Time passcode. | Passcode prompt on screen. | RUN to the prompt, then Cancel. |
| R6 | Sign out of the Apple Account, or leave Family Sharing | Account changes are restricted for a child in Family Sharing, so iOS refuses or asks for the parent. | Expected only. | **NOT RUN:** changes the Apple Account. |
| R7 | Change the date or time (turn off Set Automatically) | The Date & Time setting is locked by Screen Time on a child account, and the bedtime shield stays up. | Expected only. | **NOT RUN:** changes the date and time. |
| R8 | Turn off Location for OSRA Kids (Settings → Privacy & Security → Location Services → OSRA Kids → Never) | Allowed by iOS. On the next launch or grant report, `features.location` becomes `unavailable` and `grants.location` becomes `missing` and the parent app shows location as off. No silent failure. | Server view: both keys change within one grant report. Restore to the previous setting after. | RUN, then restore. |
| R9 | Turn off Location Services for the whole phone | Same as R8 for every app. If Screen Time locks Location Services changes, it is refused. | As R8, or the lock on screen. | RUN, then restore. |
| R10 | Airplane mode, or Wi-Fi and mobile data off | Shields and bedtime keep working (on-device). The server's `lastSeen` stops moving, and after the threshold the parent gets the "stopped checking in" alert (#681, once built). | Try a blocked app: shield shown. Server view: `lastSeen` frozen. Turn the network back on and the next sync is within a minute. | RUN, then restore. |
| R11 | Force-quit OSRA Kids from the app switcher | Shields stay. The monitor and shield extensions run without the app. Significant-change location relaunches it in the background. | Blocked app still shielded. Server view: location still arrives after a move. | RUN. |
| R12 | Turn off Background App Refresh for OSRA Kids, or Low Power Mode | Shields stay. Rule changes still arrive by push wake or on the next open, possibly slower. | Change a rule in the parent app and time the shield change (the SC-5.2 measure). | RUN, then restore. |
| R13 | Reach a blocked app another way: Spotlight, Siri, a widget, a Shortcut, or a notification | The shield appears on every path. Record any path that opens the app's content without the shield. | Screenshots of each path. | RUN. |
| R14 | Open a blocked website in Safari private browsing, or in another browser app | Web blocks from ManagedSettings apply in private browsing too. Another browser app is blocked if it's in a blocked group, or can be installed only through Ask to Buy. | Safari shows the block page. | RUN. |
| R15 | Install a VPN app or a DNS or VPN profile to get around the blocks | A new app needs the parent's Ask to Buy. A configuration profile needs the device passcode. Neither lifts the app shields, which are on-device and not network-based. | The Ask to Buy request reaches the parent. Blocked apps stay shielded. | RUN up to the Ask to Buy request. Installing a profile is **NOT RUN**: needs the device passcode. |
| R16 | Erase All Content and Settings, or restore the phone from a backup | Erase needs the device passcode (and the Screen Time passcode when restrictions are on). After a restore, the Keychain items are `ThisDeviceOnly` and not restored, so OSRA Kids asks to pair again. The parent sees the device go quiet, then a new pairing request needing approval. | Expected only. | **NOT RUN:** needs the passcode and erases the device. |
| R17 | Re-pair the phone to another family (OSRA Kids → Pair again) | Needs the parent PIN (ADR-0037). A wrong PIN is limited and counted. | The PIN gate on screen (`pin.gate`). After 5 wrong PINs, the lock line (`pin.gateMessage`). | RUN with wrong PINs only, then stop. |
| R18 | Install an older or different build of OSRA Kids over the store one | A store or TestFlight install can't be replaced by a differently signed build. A dev build later replaced by a locked build doesn't keep its old server (#678). | Covered by the #678 over-install row. | RUN on the next Kids build (#634). |

**Reporting:** one line per row in the SC-5.5 run on #665: `R<n> PASS | FAIL | NOT RUN: <reason>`, with the
evidence path. A FAIL that is a security gap goes privately to osra-security, with only a one-line pointer here.
Risk notes behind some rows are kept there too (osra-security#12).
