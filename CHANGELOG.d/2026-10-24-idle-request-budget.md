### API — the idle-request rate is counted, so 5.8's second half can become a number (#346, roadmap 5.8)
- **What the row asks and what was missing.** 5.8's acceptance is *release build passes TR-73 against HTTPS staging; idle child
  phone ≤ 3 requests per 10 min with lock still ≤ 5 s*. 1.5 measured the lock (1.0 s); **nobody ever counted the idle rate**, so
  "≤ 3 per 10 min" was a sentence with no instrument behind it.
- **Counting, and nothing else.** An `onResponse` hook records authenticated device requests per device, per minute, per
  **coarsened** route key (`GET /v1/devices/:id/commands` — identifiers replaced by `:id`/`:n`, query strings dropped). No
  bodies, no addresses, no per-command detail. A counting instrument that becomes a log of what a child did would be a privacy
  defect wearing telemetry's clothes, so the key is deliberately incapable of naming a child or a command.
- **One Redis hash per device** (`idle:dev:<deviceId>`, fields `<minute>:<route>`): one key means the reader never scans the
  keyspace, and a count cannot outlive its usefulness. Counting failures are swallowed — telemetry must never fail the request
  it is counting.
- **Counting is off unless `IDLE_BUDGET_COUNTING=1`** (architecture call, #346 review). The production default is **off**: the
  counter is a test instrument, and running it everywhere would hold roughly 54 fields per device per hour in the cache node
  that carries flags and fan-out — gigabytes of telemetry at a million devices, on a node the durable-revocation fix pins to
  `maxmemory-policy noeviction`, where a full cache makes revocation writes fail. The switch is on in the test harness
  (`vitest.config.ts`) and in staging (`infra/terraform/env/ecs.tf`, `environment == "staging"`).
- **An hour of retention, not three** (`RETENTION_MINUTES = 60`): a measurement session reads inside the hour, and 60 minutes
  still covers six 10-minute windows. Three hours held telemetry the reader never looked at.
- **One round trip per device request.** `HINCRBY` and `EXPIRE` go out as a `MULTI` (`redis.multi()…exec()`) instead of two
  awaits, so counting costs the cache one round trip rather than two. The shared `MockRedis` gained a `multi()` that applies
  the queued commands on `exec()`, so the test asserts the real chain rather than a fake.
- **The busiest window, not the average.** `summarise()` reports the current window *and* the busiest window anywhere in the
  retained range, because "≤ 3 per 10 min" is a claim about the worst window: an agent that wakes once every ten minutes and
  then four times in one of them is not idle in the sense the row means.
- **`GET /v1/devices/:id/requests`** gives a parent the counts, the window, the busiest window and the threshold, and stays
  available with counting off — where it answers `counting: false` and `withinBudget: null`, because "no data" must never read
  as "idle". Parent-only and family-scoped — the agent has no reason to read its own accounting, and a sibling device must not.
- **The threshold is empty until it is measured.** `IDLE_BUDGET_M10` unset means the probe's `P6` is a `target` that *reports*
  the count rather than a `check` that fails; Claude measures the Flip4 and supplies the number in this PR's review. A
  threshold invented here would be a gate measuring the author's guess, which is the failure this row exists to stop repeating.
- **Evidence.** `vitest`: the new file's 13 cases plus the full suite green; the two flag tests fail when the gate or the
  `counting` field is removed (mutations run and reverted). `qa-probe`: `P4` (the agent is refused its own accounting), `P5`
  (counts only, no route key carries an id), `P6` (the measurement, gated only when a threshold exists, and a `target` that
  says counting is disabled when the API was not run with the flag).
