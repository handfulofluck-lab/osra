# ADR-0012 — Durable device command queue with delivery state and acks

**Status:** Accepted · 2026-10-16 · Phase 2b of the KCL plan (`docs/QA/KCL-2026-10-16/`)

## Context

A parent pressing **Lock** had no way to know whether it reached the phone. Commands were an
`LPUSH` onto a Redis list capped at 100 plus a pub/sub message: a Redis restart dropped pending
locks silently, nothing recorded delivery, any parent JWT could drain (and so consume) the queue
(probe note B11), and the parent app's "reaches the device within ~1 minute" had nothing behind it.
`bonus_time` sent twice is not idempotent, so losing or duplicating commands has user-visible cost.

## Decision

1. **A `DeviceCommand` row per command** (migration 0011): `pending → delivered → acked | failed`,
   or `expired` when never claimed before `expiresAt`. `requestedBy` records the parent (or
   `system`), `attempts` counts claims, `result` holds the agent's ack detail.
2. **Per-type TTLs.** `ring`/`locate_now` 10 min (ringing an hour late is a bug), `rules_updated`
   24 h, consent commands 7 days, everything else 24 h. Expired `pending` rows are swept to
   `expired` on each drain and reported as such in history even before a sweep.
3. **Atomic claim.** The drain is one `UPDATE … RETURNING` so two concurrent drains never hand out
   the same row. Agents that declare `?ack=1` get delivered-but-unacked rows re-offered after 120 s,
   up to 3 attempts; agents that do not ack (today's Android and Windows builds) see each command
   once, exactly as before.
4. **Device-only drain; parents read history.** `GET /:id/commands` requires a device JWT whose
   `deviceId` matches; `POST /:id/commands/:commandId/ack` likewise; parents get
   `GET /:id/commands/history` (non-destructive, newest first). B11 is now a gating probe check.
5. **`rules_updated` coalesces** onto an existing pending row; nothing else does.
6. **Redis pub/sub stays as the wake-up signal only.** The list is gone. An agent that misses the
   message finds the row on its next poll.
7. **Wire shape is additive.** Agents still receive `[{type, payload, …}]`; `id`, `ts`, `expiresAt`
   and `attempt` are new fields existing DTOs ignore.

## Alternatives rejected

- **Keep Redis as the store with AOF persistence.** Still no delivery state, no history, no acks, and
  Redis persistence is an ops setting we cannot assume at every deployment.
- **A dedicated queue (BullMQ/SQS).** Adds infrastructure for a per-device fan-out that is a few rows
  a day; Postgres with `RETURNING` gives atomicity and the history we need.
- **Redeliver to all agents.** Would ring a non-acking phone three times. Redelivery is opt-in via
  `?ack=1` so only agents that can ack are ever re-offered a command.

## Consequences

- One Postgres write per command and one `UPDATE … RETURNING` per poll (60 s per device). Indexed on
  `(deviceId, status)` and `(deviceId, createdAt)`.
- The e2e flow now pairs an agent device (`pair` → `pair/claim`) to exercise the drain, and asserts
  pending → delivered → acked through the parent's history view (6 new checks; 56/56).
- Agents should move to `?ack=1` + `POST …/ack` to get redelivery and to light up delivered/acked in
  the parent app (Android/Windows lanes). The parent app should poll `/commands/history` for the
  status chip (Phase 3).
- `GET /:id/commands` with a parent token is now 403, a deliberate break for any client that drained
  with a parent token; none of the shipped agents do.
- Not in this ADR: a reaper for `delivered` rows of non-acking agents (they stay `delivered`, which
  is the truth), retention/cleanup of old rows (Phase 2c), WebSocket push of status changes to the
  parent app.
