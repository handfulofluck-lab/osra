### Parent app — "Add a computer" pairs a child's Windows or Mac from the child page (#627, ADR-0041 D5)
- Child page → Devices → **Add a computer** → Windows or Mac → the existing pairing screen, now told which
  computer it is for: the same `POST /v1/devices/pair` six-digit code, the same claim and Allow / Deny, the
  download address `osratech.com/windows` or `osratech.com/mac` instead of a QR (a computer has no camera),
  `Copy link`, and **Send the link**.
- **Send the link** copies the address and says where to paste it: the app ships no share plugin and this PR adds
  no dependency (ADR-0041 D5.1 allows the clipboard plus a visible line).
- The child page shows the ADR's warning when a computer's capability report says the child's own account is an
  administrator. **No client reports that fact yet** — the parent app reads the `account_admin` feature in the
  `degraded` state, and nothing sends it, so the warning cannot appear today and is not guessed at.
- New English strings only, pending the Arabic Language Bureau: `addAComputer`, `computerSelectPrompt`,
  `computerWindows`, `computerMac`, `computerAdminInstallNote`, `computerPairIntro`, `computerDownloadAddress`,
  `copyLink`, `linkCopied`, `sendTheLinkLine`, `sendTheLink`, `sendLinkCopied`, `pairClaimBodyComputer`,
  `pairClaimAllowedComputer`, `pairClaimDeniedComputer`, `computerAdminWarning`. `app_ar.arb` carries the English
  text under those keys for now (the ARB parity gate in `test/localization_test.dart` refuses a key present in
  English only); the Bureau's lines replace them.
- Tests: `test/add_computer_test.dart` (5 rows: the entry point, Windows, Mac, copy/send wiring, 320×568) and one
  row in `test/phone_setup_section_test.dart` (warning present with the fact, absent without it, and the fact is
  not also drawn as a raw-key chip).
