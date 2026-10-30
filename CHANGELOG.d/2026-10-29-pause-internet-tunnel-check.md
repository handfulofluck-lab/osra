### Child agent — `pause_internet` acks a tunnel that exists, not a service that started (#234)
- `FilterVpnService.start()` only posts a start intent, so the old ack reported `ok` whenever the filter
  was **consented and prepared**. A phone whose tunnel never came up kept passing every packet while the
  parent read "paused" — a false claim about the one thing the command exists to do.
- **The first attempt waited on the wrong signal, and the review caught it.** `FilterVpnService.isRunning`
  is set in `onCreate`, before `establish()`, and stays true when `establish()` returns `null` — the
  service lives on with no descriptor. So it answered "the service object exists", which is true in
  exactly the two cases this fix is about: a filter already running in DNS mode (the ack lands before the
  re-mode) and a cold start whose `establish()` failed.
- **What is waited on now:** `FilterVpnService.tunnelMode`, written only after `establish()` returned a
  descriptor and cleared at the top of `stopTunnel` (which every re-mode calls first). The dispatcher
  waits for `tunnelMode == MODE_SINKHOLE_ALL`, boundedly — **1500 ms**, raised from an unmeasured 400 ms
  because a cold `startForegroundService` → `establish()` under Doze can legitimately take longer, and a
  false failure would report the opposite of what happened. The wait runs on a worker thread only; the
  KDoc says so, because the work it waits for needs the main thread.
- The refusal keeps its own reason, `web_filter_start_failed`, distinct from `web_filter_not_set_up`:
  "re-enable the filter" and "find out why the tunnel will not start" are different instructions. The
  parent app now has a sentence for it, in English and Arabic, instead of the raw code.
- JVM: `isSinkholeEstablished` rows (sinkhole → true; `dns` → false; null → false), the never-up refusal,
  its `failed` ack with `detail.reason = web_filter_start_failed`, and three wait rows (already up → no
  sleep; up on the third poll → 50 ms; never up → gives up at the deadline).
  **Limit stated rather than hidden:** the rows pin the predicate, not the `stopTunnel` wiring — driving
  that needs Robolectric, which this project does not use. The wiring is covered by inspection and by the
  Flip4 rows, and no hardware evidence is claimed until Claude runs them.
