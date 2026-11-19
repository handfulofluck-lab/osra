### iOS — four of KP01's PIN rows now run on the simulator (#739)
- The seed added in #933 makes the parent-PIN screens reachable without pairing; this change spends it on the rows
  the catalogue actually asks for, so they stop being hand-run.
- **A PIN longer than eight digits is refused** with the app's own line, and the screen stays put (E12's long case).
- **A pasted PIN is judged by the same rules as a typed one**: twelve digits pasted through the pasteboard are
  refused as too long rather than silently truncated to eight. The catalogue's letter case is not reachable through
  the field's number pad, so it is a follow-up row rather than a claim made here.
- **The attempt count survives a relaunch**: two wrong attempts, a killed app, then a third leaves two of five —
  which is only true if the counter came back with the app. The relaunch deliberately carries no seed, because the
  seed wipes the identity and PIN and would reset the very thing the row measures.
- **A fast double tap on save neither crashes nor stalls.** Stated honestly: a UI test cannot see how many times the
  Keychain was written, so a duplicate write of the same value would pass. The catalogue asks for "no crash, no
  pass", and that is what the row asserts.
- Every assertion compares against a line the app renders (`ParentPin.validationError`, `PinGateMessage`) rather
  than a sentence written in the test, so a wording change moves the test with the app.
- Verified: all four rows passed on the GitHub macOS simulator runner (`iOS CI`, `PinRulesSeededTests`, 92.5 s
  across the four cases), after two rounds in which the paste and double-tap rows failed on their own wording and
  were rewritten. There is still no Xcode on the author's PC, which is why the first execution was CI's.
