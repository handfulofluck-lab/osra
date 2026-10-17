# ADR-0013 — Durable usage model, data retention, and a complete erasure cascade

**Status:** Accepted · 2026-10-16 · Phase 2c of the KCL plan (`docs/QA/KCL-2026-10-16/`)

## Context

"Screen time today" lived only in Redis (`usage:child:<id>:<day>`, 48 h TTL), so a flush or restart
read as *0 minutes*; the weekly report was a JSON scan over `ActivityEvent` with nothing to fall back
on once events aged out; browsing history was the same scan; nothing ever deleted raw events; and the
GDPR erasure cascade (`DELETE /v1/family/children/:id`) left `ActivityEvent`, `SocialEvent`,
`InstallRequest` and `DeviceCommand` rows orphaned, and the devices' 10-year JWTs usable. The
assessment's headline finding #8. Acceptance for the phase: *weekly report correct after a Redis
flush; erasure leaves zero rows.*

## Decision

1. **Two rollup tables** (migration 0013). `AppUsageDaily` (child × device × UTC day × app → minutes,
   unique) and `WebVisit` (one row per URL event: domain, url, blocked, category). Time columns are
   `TIMESTAMPTZ`; `day` is a `DATE` in UTC (issue #53 rules apply: instants bound from JS, never
   `NOW()`).
2. **Ingestion writes them incrementally; the nightly job reconciles.** `POST /devices/:id/activity`
   upserts-with-increment per (day, app) and inserts `WebVisit` rows; `POST /devices/:id/telemetry`
   adds the device-reported `totalMinutes` under the reserved app name `*`. At `ROLLUP_HOUR_UTC`
   (default 02:00) the scheduler recomputes *yesterday's* per-app rows from `ActivityEvent` and
   **overwrites** them (idempotent), so a missed or doubled increment self-heals. Device totals (`*`)
   come only from telemetry and are not reconciled.
3. **Reads prefer the durable table.** `/v1/family/me` uses the Redis counter when present and falls
   back to `AppUsageDaily` for today (device totals if any device reported one, else the per-app sum).
   New `GET /v1/reports/usage?childId&days` (per-day series with per-app split, zeros for empty days)
   and `GET /v1/reports/web?childId&days&limit&blocked&domain` (browsing history) read only Postgres.
4. **Retention.** Raw rows — `ActivityEvent`, `WebVisit`, `SocialEvent`, `LocationPing` — are deleted
   after `RETENTION_DAYS` (default 90, floor 7); rollups after `ROLLUP_RETENTION_DAYS` (default 365,
   never below the raw window). Runs after the rollup, in the same claimed job.
5. **One erasure function.** `eraseChildData()` lists every child-scoped table in FK order
   (`CHILD_SCOPED_DELETE_ORDER`, asserted by a unit test so the list cannot silently fall behind the
   schema), deletes in one transaction, returns the per-table counts, then revokes each deleted
   device's token exactly as an unpair does (`revoked:device:<id>` with the token-lifetime TTL, #56)
   and drops the child's and devices' Redis keys.
6. **Same job pattern as the digests** (ADR-0011): hourly tick, `SET NX` claim per day so several
   API instances do not double-run, `JOBS_ENABLED=0` for an external cron that calls
   `runUsageRollup()`.

## Reasoning

- A per-day table is the smallest shape that answers "how much, which apps, which day" without a
  scan, keeps working after raw retention, and is cheap enough to keep for a year.
- Incremental writes give the parent app a live number; the overwrite-reconcile makes the number
  *right* regardless of what happened to the increments. Doing only one of the two would mean either
  stale charts or unverifiable ones.
- Device totals and per-app minutes are different measurements (an agent can report a day total it
  cannot attribute per app). Keeping `*` separate avoids double counting and lets a day's headline
  number come from whichever is available.
- Erasure listing in one place, with a test pinning the list, is the only way the cascade stays
  complete as models are added. The row counts in the response turn "erased" into something a gate
  can check (e2e counts the rows in Postgres afterwards).
- Revoking tokens on erasure closes a gap the unpair path did not have: a device of an erased child
  could still present a valid JWT; every route also checked `requireFamily`, which failed on the
  missing row, but relying on that is the kind of accidental control this repo tries not to keep.

## Alternatives considered

- **Keep Redis as the store and persist it** (AOF) — still one store, still no history, still
  invisible to SQL; rejected.
- **Materialised view over `ActivityEvent`** — correct only while the raw rows exist, i.e. the
  retention job would erase the report it feeds; rejected.
- **Hourly buckets** — more rows, no product need yet (charts are daily/weekly); daily chosen, the
  table can gain an `hour` column later without changing the reads.
- **`ON DELETE CASCADE` on every child FK** — would make erasure implicit and uncounted; several
  tables (`ActivityEvent`, `SocialEvent`, `InstallRequest`, the rollups) deliberately have no FK to
  `Child` so ingestion cannot be blocked by a parent-side delete; explicit cascade chosen.

## Consequences

- **Good:** charts and reports no longer depend on Redis; a database is the only thing a tester
  needs to reason about; erasure is verifiable; data has a lifetime.
- **Cost:** one more write per ingested batch (an upsert per (day, app) plus one `createMany`) —
  wrapped in try/catch so a rollup failure never rejects the batch; a daily job that must be running
  somewhere (in-process by default); 90-day retention is a product decision that regulators or
  parents may want configurable per family — today it is global.
- **Not done:** per-family retention settings; a retention notice in the parent app; backfilling
  rollups for days before this change (the nightly job only reconciles yesterday; older days roll up
  on demand only if someone calls `rollupDay()` for them — not exposed as a route).

## Evidence

- Unit: `services/api/test/usage-model.test.ts` (13 tests — bucketing, UTC day, reads, rollup
  overwrite, retention cutoffs bound from JS, erasure list, scheduler claim) and the extended cascade
  test in `test/family.test.ts`.
- Live, database created from zero in `Asia/Dubai`: e2e **66/66** — after `DEL usage:child:*`,
  `/v1/family/me` still reports 30 min; `/reports/usage` shows YouTube 21 / Roblox 9 with the live
  heartbeat excluded; erasure returns the counts and a Postgres count afterwards is **0 in all 13
  tables**; the erased child's device JWT → 401. Probe **95/0** (M1–M6, B5/B5b). Rollup run twice on
  seeded rows: a stale 999-minute row overwritten to 17, a 107-day-old event reaped, second run
  identical.
