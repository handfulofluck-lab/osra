### Child agent — the status screen stops claiming protection the moment the phone is unlinked (#471)
- Found on the Flip4 during the #466 row: after the family was deleted and the agent had unlinked
  itself, the still-visible status screen read "This device is paired … ✓ Protection: device admin
  (uninstall needs the parent PIN) … ✓ Web filter: connected" while `dumpsys device_policy` already
  reported no admin and `FilterVpnService` was gone. Force-stopping the app showed the pairing form, so
  the state was right and only the screen was stale — the two worst sentences to be wrong, because they
  tell a child the phone is still watched and that uninstalling needs a parent who no longer exists.
- `DeviceUnlinker` now sends a package-scoped broadcast (`DeviceUnlinker.ACTION_UNLINKED`) once the
  sequence has run, after the steps rather than before them. `PairingActivity` registers for it while
  started (`RECEIVER_NOT_EXPORTED`, released in `onStop`) and **re-reads the pair state** instead of
  trusting the payload: `if (!settings.isPaired()) showForm(...)`.
- Rows: `UnlinkedRefreshWiringTest` (four source-text assertions: one action constant, a package-scoped
  send that follows the steps, a `started`-scoped registration that is released, and a re-render that
  reads the pair state). Mutants: drop `sendBroadcast` → first two rows red; drop `registerReceiver` →
  the third; swap the order → the "announces after the sequence" row.
- **Not verified by a JVM row, and stated as such:** that a broadcast actually re-renders the screen on
  a device. That is the Flip4 row (status screen in the foreground, then an unlink), and Claude's phone
  queue owns it.
