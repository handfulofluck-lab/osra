### API — alerts are kept for 12 months, not for ever (Play decision 10 B)
- **Before:** `applyRetention` deleted activity events, web visits, social events, location pings and daily
  usage, but **not alerts**. A child's alerts went only when the child was erased, so the data-safety answer
  could not honestly describe a retention period.
- **After:** alerts are deleted at **365 days** by the same nightly job, through `alertRetentionDays()` with
  the same pattern the location window uses. `ALERT_RETENTION_DAYS` may **lower** it but never raise it — a
  mistyped override must not make the product keep a child's alerts for ever — and an unusable value takes
  the 365-day default.
- Rows: `usage-model.test.ts` gains a boundary row (a 366-day-old alert is deleted, a 364-day-old one is kept)
  and a clamping row (30 honoured, 1000 clamped to 365, garbage falls back to 365), and the existing retention
  rows now assert the alert cutoff alongside the others. API suite **809/809**.
