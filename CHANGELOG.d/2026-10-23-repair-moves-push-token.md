### Child agent — a re-pair moves the push token at once, instead of at the next poll (#332)
- **The defect, found on the 1.5 push row.** After a re-pair the push token stayed on the **old** device row
  until the next poll ran. Measured on staging (Flip4, agent from main `bbda837`): re-pair at 13:59:25, a
  `ring` to the new row at 14:01:28 woke nothing for **91 s**, while an `unlock` to the **old** row
  at 14:02:58 woke the phone. The poll that finally ran at 14:02:59 uploaded the token and drained the
  pending commands.
- **Cause, on the agent only.** `CommandPoller` is the one place the token is uploaded, and `clearPairing`
  correctly forgets the uploaded marker — but nothing polls at pairing time: `WorkScheduler.scheduleAll`
  enqueues the periodic poll with `ExistingPeriodicWorkPolicy.KEEP`, so on a re-pair the old schedule is
  kept and no poll runs. A first pairing escapes this only because a newly enqueued periodic worker runs
  immediately. The server side was already right: #323 moves the token and clears the old row.
- **Fix: one call.** `PairingActivity.startAgent()` — the function every successful claim runs after
  `settings.savePairing(...)` — now runs `CommandPollWorker.requestFetchNow(this)`, the same expedited,
  network-constrained, `KEEP` one-shot the push fallback uses, so a burst collapses into one fetch.
- **Measured with the patch, on the phone:** claim at 14:16:10.022, `push-token` `204` for the new row at
  14:16:10.776 (**0.75 s**), then `commands` at 14:16:11.090. A command to the new row woke the phone
  (fetch 2.8 s); a command to the previous row woke nothing.
- **Tests:** `PairingStartAgentWiringTest` (2, source-level because the activity cannot run in a JVM test):
  `startAgent()` calls `requestFetchNow(this)`, and the claim's `onSuccess` saves the pairing **then** starts
  the agent. Mutant: delete the call and the first test fails with the reason in the message.
  `testPlayDebugUnitTest` and `testFullDebugUnitTest` **623 each, 0 failures** (621 on main plus these 2).
- **Not claimed here:** the JVM tests prove the wiring, not the device; the phone measurement above is
  Claude's run and is recorded in `docs/ROADMAP.md` row 1.5, which this change moves to **MET**.
