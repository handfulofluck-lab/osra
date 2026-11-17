### API — a restarted child phone now says so, in 1–2 minutes instead of never (#867)
- **The gap:** a phone restart takes 1–2 minutes. The silence watch is 30 minutes on purpose
  (`SILENT_MIN_SAFE_MINUTES` = two 15-minute telemetry intervals), because a false `device_silent`
  critical is worse than a late true one, so lowering the window was never the fix. The device has to
  report the restart, and now it does: `POST /v1/devices/:id/telemetry` accepts an optional `bootedAt`
  (ISO-8601 UTC, the agent's `now − SystemClock.elapsedRealtime()`) and `bootCount` (Android's
  `Settings.Global.BOOT_COUNT`).
- **What decides (#884 review, Fable's blocker 2):** `elapsedRealtime` is monotonic but the wall clock is
  not, so an instant-only rule let a child move the clock and manufacture one restart alert per telemetry
  tick. When the report and the stored row both carry a `bootCount`, **the counts decide** and the instant
  only dates the alert and sizes the gap: equal is the same boot (a moved clock writes nothing), higher is
  a restart, and lower — a wipe, a restore, an earlier counter — is a new baseline with no alert, never
  tampering. Where either side has no count (an older agent), the comparison falls back to the 90-second
  instant rule, and the code comment says plainly that the fallback keeps the clock-move weakness until
  the first count-bearing report is stored.
- **Server half:** `Device.lastBootAt` and `Device.lastBootCount` (migration `0035_device_last_boot_at`).
  A restart raises one `device_restarted` alert through `raiseAlertOnce` — `info`, or `warning` when the
  gap reaches 30 minutes (the point the parent would also have received `device_silent`). The body reads
  `Pixel 7a restarted at 14:32, back after 2 minutes.` in the family's own timezone. A repeated tick writes
  nothing and raises nothing; a `bootedAt` more than five minutes in the future is dropped and logged
  without failing the upload.
- **First report is silent (#884 review, Fable's blocker 1):** with nothing stored there is no earlier
  boot to compare against, so the first report from a phone — and the first after a counter reset — stores
  the baseline and raises **nothing**. An alert there would tell every family on ship day about a boot the
  server cannot know is news.
- The stored values are on the parent's device read as `lastBootAt`/`lastBootCount`, and
  `device_restarted` is in the shared `Alert` category union. No push or email template change: the alert
  is already visible in the alerts list because the server supplies its title and body. It still has no
  `bodyKey`, so it reads in English in an Arabic app — a follow-up, not this PR.
- **Agent half, in the same PR:** `TelemetryDto.bootedAt` and `TelemetryDto.bootCount` ride every
  telemetry upload from all three call sites (periodic aggregate, capability report, location-grant
  report). The count is `Settings.Global.getInt(contentResolver, "boot_count", -1)` with `-1` sent as
  absent; it needs no permission. Both are sent every tick rather than only after a restart because the
  server is the side that remembers the last value: a client-side "already sent" flag would be a second
  source of truth that a `pm clear` desynchronises from the server's.
- **Not run here:** the live `qa-probe`/`e2e` gates (no stack on this machine) and any hardware row. On the
  server the evidence is `pnpm --filter @familyshield/api test` on the three touched files — **79 passed**
  (boot-report 13, devices 51, device-silence 15) — and `npx tsc --noEmit` clean. A **full-suite run could
  not finish on this host** after these fixes: the normal pool never spawned a worker (0 CPU after 13
  minutes), and the single-fork run was still going after ten minutes on a machine shared with other
  agents, so no full-suite claim is made for this tree (the pre-review tree's full run was 1153 passed).
  The Kotlin compile and `BootClockTest` are CI's, not this machine's — the local Gradle daemon is
  unusable here. **The hardware row this PR cannot supply:** one real restart on the Flip4 showing the
  alert arrive with the right gap, and one clock change showing it does not arrive.
