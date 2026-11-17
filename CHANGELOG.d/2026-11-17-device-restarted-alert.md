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
- **Not in this PR, and it is why nothing changes for a parent yet:** no client sends `bootedAt` — the
  Android/iOS agent change is a separate PR — so every device simply keeps `lastBootAt` null, and its
  first report after an agent ships that field is treated as a new boot once. Not run: the live
  `qa-probe`/`e2e` gates (no stack here) and any hardware row; `pnpm --filter @familyshield/api test` is
  the evidence.
