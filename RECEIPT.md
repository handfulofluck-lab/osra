# C-03 Arabic frame receipt

- Source PR: #1196
- Exact source head: `2250e38c538f0916ed149ebb0838638a8c2ad152`
- Capture: `kimimac-c01`, Android 15 ARM64 (`google_apis_playstore` revision 9), emulator 37.3.10
- APK: Full Debug, `testOnly`, built from the source head plus an uncommitted debug-only capture activity. No production source change was pushed.
- Rendering: production `AskParentScreen`, `AskSendState`, and existing approved Arabic resource strings. Ask, pending, and send-failed are local UI fixtures; the images are not network-delivery evidence.
- 390 frames: 390x844 pixels, 100% text.
- 320 frames: 320x568 pixels, 200% text. The two send-failed frames are scrolled slightly within the content area to show the complete retry action and error.
- No pairing, network request, physical phone, Codex emulator, signing material, or real family data was used.
- Visual inspection: all 12 PNGs opened and checked for light/dark, clipping, horizontal overflow, RTL mirroring, pending state, and retryable failure state.

Files: 12 PNGs plus this receipt.
