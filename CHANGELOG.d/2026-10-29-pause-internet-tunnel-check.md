### Child agent — `pause_internet` no longer acks `ok` for a tunnel that never started (#234)
- `FilterVpnService.start()` only posts the start intent (`FilterVpnService.kt:310-314`), so the old ack
  reported `ok` whenever the filter was **consented and prepared**. A phone whose service never came up
  kept passing every packet while the parent read "paused" — a false claim about the one thing the
  command exists to do.
- The agent now waits, boundedly, for the service's own `isRunning` flag — 400 ms, polled every 25 ms —
  and refuses with `web_filter_start_failed` when it does not appear. `web_filter_not_set_up` keeps its
  meaning, because the parent's fix differs: re-enable the filter, or find out why the tunnel will not
  start.
- The paused state is persisted before the wait either way, so the pause applies as soon as the tunnel
  does run; the ack describes the phone now, not later.
- `EnforceabilityPolicy.awaitFilterRunning` takes its clock and sleep function as parameters, so the JVM
  rows state the deadline without spending it: already up → no sleep at all; up on the third poll →
  50 ms; never up → gives up exactly at the deadline instead of wedging the worker.
- JVM: `EnforceabilityPolicyTest` adds the never-up refusal, its `failed` ack with
  `detail.reason = web_filter_start_failed`, and the three wait rows. **No hardware evidence is claimed.**
  A phone row would need the tunnel to be denied at start, which is Claude's to schedule under the §9
  lease — until then this is a code-level claim only.
