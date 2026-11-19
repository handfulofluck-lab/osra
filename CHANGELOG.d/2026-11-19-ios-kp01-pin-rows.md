### iOS — four of KP01's PIN rows now run on the simulator (#739)
- The seed added in #933 makes the parent-PIN screens reachable without pairing; this change spends it on the rows
  the catalogue actually asks for, so they stop being hand-run.
- **A PIN longer than eight digits is refused** with the app's own line, and the screen stays put (E12's long case).
- **A pasted PIN is judged like a typed one**: a value containing a letter is refused as not digits rather than
  silently cleaned, which is the failure mode a character-filtered field invites.
- **The attempt count survives a relaunch**: two wrong attempts, a killed app, then a third leaves two of five —
  which is only true if the counter came back with the app. The relaunch deliberately carries no seed, because the
  seed wipes the identity and PIN and would reset the very thing the row measures.
- **A fast double tap on save neither crashes nor stalls.** Stated honestly: a UI test cannot see how many times the
  Keychain was written, so a duplicate write of the same value would pass. The catalogue asks for "no crash, no
  pass", and that is what the row asserts.
- Every assertion compares against a line the app renders (`ParentPin.validationError`, `PinGateMessage`) rather
  than a sentence written in the test, so a wording change moves the test with the app.
- Verified: CI only. There is no Xcode on this PC, so these four rows have never executed; the pull request says so.
