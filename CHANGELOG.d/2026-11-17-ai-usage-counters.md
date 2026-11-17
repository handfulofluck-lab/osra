### API — each family's scanning is counted, so a price can be set from data (#890)
- New `AiScanUsage` row per (family, family-local day) with two counters: `scans` (every capture classified)
  and `aiCalls` (the subset that reached the AI engine, which is the only part that costs money). The
  local pattern pass is free, so a family that only ever hits local patterns shows a real number and a zero
  bill — counting both as one would overstate every family's cost, which is the opposite of what the pricing
  debate needs.
- Recorded in `routes/social.ts` at the single place a capture is classified, so the batch path and the
  single path are counted identically. Best-effort by contract: a counter that fails logs and is lost; it
  never turns a served scan into a 500, and a missed increment is a rounding error in a monthly figure.
- `day` is the family's own calendar day (`Family.timezone`), stored as text, because a date column would be
  read back in UTC and move a Dubai family's evening into the next day.
- Migration `0039_ai_scan_usage` is additive and starts empty: no earlier scan was ever recorded anywhere, so
  there is nothing to backfill and the first month is the first honest number.
- **What this number is, and is not (#897 review).** It is **volume per family**: scans, and the subset where an
  AI request was actually made — an attempt that opened a connection and then timed out counts, because it was
  paid for, while a refused connection does not. It is **not** spend: the engine decides internally whether its
  own model or Bedrock answered, so `stage1` and `escalations` would need the engine to report which stage
  answered, and until it does the cost split the pricing debate turns on is invisible here. The row that makes
  a price from this must not pretend otherwise.
- Retention: kept while the family exists and deleted with it (the §4 guard forced that decision on the day the
  model was added). One row per family per day is a few kilobytes a year, so no sweep owns it yet.
- **Not in this PR:** no endpoint and no screen. The counters are for the cost question, and exposing them
  needs the tier decision first (a parent-facing usage figure is a product choice, not a counter).
- Verified: `npx vitest run test/social.test.ts` **29 passed** (two new rows), each row watched failing
  against the old route first (**2 failed | 27 passed**); `tsc --noEmit` clean. Not run: the live
  `qa-probe`/`e2e` gates — no stack on this machine.
