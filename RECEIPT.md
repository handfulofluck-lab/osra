# C-01 frame receipt

- Source PR: #1191
- Exact source head: `f9c8475b99b6b0496344d51f241ef8344b0d45ae`
- Capture: `kimimac-c01`, Android 15 ARM64 (`google_apis_playstore` revision 9), emulator 37.3.10
- APK: Full Debug, `testOnly`, built from the source head plus an uncommitted debug-only capture activity and debug-only legacy-routing fixture. No production source change was pushed.
- Rendering: production `ChildHomeScreen` and existing EN/AR resource strings. The flag-off image renders the production `PairingActivity` legacy status path.
- 390 frames: 390x844 pixels, 100% text.
- 320 frames: 320x568 pixels, 200% text; lower content remains reachable by the screen's vertical scroll.
- No pairing, network request, physical phone, Codex emulator, signing material, or real family data was used.
- Visual inspection: all 9 PNGs opened and checked for EN/AR, light/dark, clipping, horizontal overflow, RTL mirroring, SOS presentation, and flag-off behavior.

Files: 9 PNGs plus this receipt.
