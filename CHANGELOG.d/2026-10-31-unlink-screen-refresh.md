### Child agent — the status screen stops claiming protection the moment the phone is unlinked (#471)
- Found on the Flip4 during the #466 row: after the family was deleted and the agent had unlinked
  itself, the still-visible status screen read "This device is paired … ✓ Protection: device admin
  (uninstall needs the parent PIN) … ✓ Web filter: connected" while `dumpsys device_policy` already
  reported no admin and `FilterVpnService` was gone. Force-stopping the app showed the pairing form, so
  the state was right and only the screen was stale — the two worst sentences to be wrong, because they
  tell a child the phone is still watched and that uninstalling needs a parent who no longer exists.
- **Two refresh paths, because one is not enough.** While the screen is started, `DeviceUnlinker`
  sends a package-scoped broadcast (`ACTION_UNLINKED`, after the steps rather than before them) and
  `PairingActivity` re-reads the pair state instead of trusting the payload. On return from the
  background the receiver has been released in `onStop`, so `onResume` carries the other half: when the
  phone is unpaired **and the status screen is the one on display**, it renders the pairing form.
  A `statusScreenShown` flag (set by `showStatus`, cleared by `showForm`) is what keeps a half-typed
  pairing form from being replaced by either path.
- Rows: `UnlinkedRefreshWiringTest` (four rows: one action constant, a package-scoped send that follows
  the steps, a `started`-scoped registration that is released, and the `onResume` unpaired branch with
  the flag it depends on). Mutants: drop `sendBroadcast` → a row red; drop `registerReceiver` → a row
  red; swap the order → the ordering row; delete the `onResume` branch → the fourth (this last one was
  a real hole the first version shipped, caught in review).
- **Not verified by a JVM row, and stated as such:** that a broadcast actually re-renders the screen on
  a device. That is the Flip4 row (status screen in the foreground, then an unlink), and Claude's phone
  queue owns it.
