### Child agent (Full) — a restart harvests what is already in the SMS table, before its first flush (#520)
- **What was seen.** After a force-stop, two texts already in the SMS table stayed off the server through two
  5-minute flushes and landed only when another text arrived and the app was opened. Nothing lost, nothing
  doubled — but a text could sit unharvested for a long time.
- **The cause was ordering, not a missing path.** `start()` registered the observers and then waited a full
  period before its first harvest, so a flush could upload a table nobody had read yet.
- **The fix.** The body of `onPermissionsChanged()` — register what is allowed now, note the consent state, skip
  when paused, harvest each registered stream — is now a suspendable `harvestNow()`, and `start()` runs it
  **before** its first flush. A restart therefore harvests immediately instead of waiting for the next text or
  an app open.
- **The public entry point keeps its shape.** `onPermissionsChanged()` still returns immediately and launches
  the same body, because its callers are synchronous Android callbacks (the permission result, `onResume`, the
  loop); the two cannot drift because there is one body.
- Rows: `CommsStartHarvestWiringTest` (3) — the start path harvests, the loop still harvests on every tick, the
  harvest precedes the flush, and the retry entry point launches the same body.
- Mutants: delete the start-time `harvestNow()` and the first row goes red; move it after the flush and the
  ordering row goes red.
- **Play is unaffected:** the artefact declares neither `READ_SMS` nor `READ_CALL_LOG`, and `start()` returns
  before registering anything when `CAPTURE_CALL_SMS` is false.
