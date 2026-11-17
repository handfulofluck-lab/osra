### API — the per-app split in telemetry now reaches the usage report (#830 S1)
- `POST /v1/devices/:id/telemetry` already carried `appUsage` and the parent's report was still empty for
  every family: the only per-app writer (`recordActivityUsage`) is fed by **persistent** activity events, and
  the Android agent marks all of its own `app_usage` events `live`, which the activity route filters out on
  purpose (BUG-002). The total came from `totalMinutes`; the breakdown had no writer at all.
- New `recordAppUsage` folds those entries into the same `AppUsageDaily` rows, day-keyed in one place with
  `addMinutes`. `*` is skipped — the total keeps its single writer, so a second writer cannot double it —
  zero-minute entries create no row, entries beyond 200 are ignored (a phone cannot truthfully report more in
  one tick), and a failure costs the rollup, not the telemetry upload: the increment re-reports next tick.
- Server-only: no agent change, so the parent gets an app breakdown for every device from the next tick after
  deploy. The remaining #830 gaps (blocked-attempt alerts, web history, calls/SMS events) are diagnosed on
  the issue: the first needs an agent counter, the second a privacy decision from Ahmed, the third has no
  producer at all.
- Verified: `npx vitest run test/devices.test.ts` **53 passed** with two new rows, each watched failing
  against the old handler first; `tsc --noEmit` clean. Not run: live `qa-probe`/`e2e` (no stack here).
