# C-05 frame receipt

- Source PR: #1208
- Exact source head: `a79a1748703729d5d7e0ad56a79a5aa9759a24a2`
- Capture: `kimimac-c01`, Android 15 ARM64 (`google_apis_playstore` revision 9), emulator 37.3.10
- APK: Full Debug, `testOnly`, built from the source head plus an uncommitted debug-only capture activity and debug-only pairing-routing fixture. No production source change was pushed.
- Rendering: production welcome, permission-step and family-agreement composables with existing EN/AR resource strings; production `PairingActivity` for hand-off and flag-off views. No pairing or network request was made.
- Flag-on matrix: welcome, accessibility permission with the restricted-settings guide and `Open app info` directly after step 1, pairing hand-off, and agreement-last screens; EN + AR, light + dark, 390x844 and 320x568 at 200% text.
- Flag-off: shipped welcome without the C-05 transparency or roadmap cards.
- Eight `_scrolled` companions show the complete compact roadmap/Start and optional Call Log/SMS/finish sections.
- Visual inspection: all 41 PNGs opened and checked for EN/AR, light/dark, clipping, horizontal overflow, RTL mirroring and required content.
- Triage note: the existing native pairing hand-off clips the long server-URL hint at 320x568 at 200% text in EN and AR. The input and both pairing actions remain visible. The native hand-off does not change its light appearance in night mode. These are existing native-view limitations, not C-05 composable regressions; the Bureau/lead should triage them.
- No physical phone, Codex emulator, signing material, real family data, or network-delivery claim.

Files: 41 PNGs plus this receipt.
