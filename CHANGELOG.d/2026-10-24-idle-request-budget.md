### API — the idle-request rate is counted, so 5.8's second half can become a number (#346, roadmap 5.8)
- **What the row asks and what was missing.** 5.8's acceptance is *release build passes TR-73 against HTTPS staging; idle child
  phone ≤ 3 requests per 10 min with lock still ≤ 5 s*. 1.5 measured the lock (1.0 s); **nobody ever counted the idle rate**, so
  "≤ 3 per 10 min" was a sentence with no instrument behind it.
- **Counting, and nothing else.** An `onResponse` hook records authenticated device requests per device, per minute, per
  **coarsened** route key (`GET /v1/devices/:id/commands` — identifiers replaced by `:id`/`:n`, query strings dropped). No
  bodies, no addresses, no per-command detail. A counting instrument that becomes a log of what a child did would be a privacy
  defect wearing telemetry's clothes, so the key is deliberately incapable of naming a child or a command.
- **One Redis hash per device** (`idle:dev:<deviceId>`, fields `<minute>:<route>`), expiring after three hours: one key means
  the reader never scans the keyspace, and a count cannot outlive its usefulness. Counting failures are swallowed — telemetry
  must never fail the request it is counting.
- **The busiest window, not the average.** `summarise()` reports the current window *and* the busiest window anywhere in the
  retained range, because "≤ 3 per 10 min" is a claim about the worst window: an agent that wakes once every ten minutes and
  then four times in one of them is not idle in the sense the row means.
- **`GET /v1/devices/:id/requests`** gives a parent the counts, the window, the busiest window and the threshold. Parent-only and
  family-scoped — the agent has no reason to read its own accounting, and a sibling device must not.
- **The threshold is empty until it is measured.** `IDLE_BUDGET_M10` unset means the probe's `P6` is a `target` that *reports*
  the count rather than a `check` that fails; Claude measures the Flip4 and supplies the number in this PR's review. A
  threshold invented here would be a gate measuring the author's guess, which is the failure this row exists to stop repeating.
- **Evidence.** `vitest`: the new file's 8 cases plus the full suite green. `qa-probe`: `P4` (the agent is refused its own
  accounting), `P5` (counts only, no route key carries an id), `P6` (the measurement, gated only when a threshold exists).
