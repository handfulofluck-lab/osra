### iOS — backgrounding mid-entry must not bypass the gate or reset the attempts (#739)
- The last KP01 catalogue line a simulator can reach: a child leaves the app with a half-typed PIN, comes back, and
  must still be asked — with the attempts already spent still spent.
- **The row asserts both halves in one test on purpose**: the gated action still asks after the trip to the
  background, **and** a second wrong PIN reports three tries left rather than four. Either alone passes a broken app.
- **The first version asserted nothing, and two reviewers caught it.** It typed two digits, backgrounded, and then
  checked "four tries left" — but a typed digit spends no attempt, because `ParentPinStore.check` runs only when
  Continue is tapped. Four is what a fresh counter reports too, so a non-persistent lockout passed. The row now
  spends an attempt *before* backgrounding.
- **A premise corrected before the first run:** the row originally required the gate sheet to survive backgrounding.
  It need not — iOS may dismiss a presented sheet, and the status screen behind it is not gated; the action is. The
  row re-opens the action when the sheet is gone.
- Verified: passed on the simulator in 49.1 s, then rewritten for the reviewer's finding; the rewritten row's first
  execution is the pull request.
