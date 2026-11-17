### API — a restarted child phone now says so, in 1–2 minutes instead of never (#867)
- **The gap:** a phone restart takes 1–2 minutes. The silence watch is 30 minutes on purpose
  (`SILENT_MIN_SAFE_MINUTES` = two 15-minute telemetry intervals), because a false `device_silent`
  critical is worse than a late true one, so lowering the window was never the fix. The device has to
  report the restart, and now it can: `POST /v1/devices/:id/telemetry` accepts an optional `bootedAt`
  (ISO-8601 UTC, the agent's `now − SystemClock.elapsedRealtime()`), a value that is stable for the life
  of one boot.
- **Server half:** `Device.lastBootAt` (migration `0035_device_last_boot_at`) stores the instant. A report
  that moves it by more than 90 seconds is a new boot and raises one `device_restarted` alert through
  `raiseAlertOnce` — `info`, or `warning` when the gap reaches 30 minutes (the point the parent would also
  have received `device_silent`). The body reads `Pixel 7a restarted at 14:32, back after 2 minutes.` in
  the family's own timezone. A repeated tick with the same instant writes nothing and raises nothing; a
  `bootedAt` more than five minutes in the future is dropped and logged without failing the upload.
- The stored value is on the parent's device read as `lastBootAt`, and `device_restarted` is in the shared
  `Alert` category union. No push or email template change: the alert is already visible in the alerts
  list because the server supplies its title and body.
- **Agent half, in the same PR:** `TelemetryDto.bootedAt` (`BootClock.bootedAtIso(nowMs, elapsedRealtimeMs)`,
  truncated to whole seconds) rides every telemetry upload from all three call sites — the periodic
  aggregate, the capability report and the location-grant report. It is sent every tick rather than only
  after a restart because the server is the side that remembers the last value: a client-side "already
  sent" flag would be a second source of truth that a `pm clear` desynchronises from the server's.
- **Not run here:** the live `qa-probe`/`e2e` gates (no stack on this machine) and any hardware row. The
  evidence is `pnpm --filter @familyshield/api test` (1153 passed) plus a targeted re-run of the three
  touched files (69 passed) after the Android commit was folded in, and CI for the Kotlin compile —
  the local Gradle daemon is unusable on this machine, so `BootClockTest` is compiled and run by CI, not
  here. **The hardware row that this PR cannot supply:** one real restart on the Flip4 showing the alert
  arrive with the right gap.
