# ADR-0032 — Revocations are stored in Postgres; Redis is only a cache

- **Status:** accepted
- **Date:** 2026-10-24
- **Deciders:** Claude (architecture + testing), from the private finding
  `handfulofluck-lab/osra-security#1`; implemented by Kimi Code (development lead), roadmap 2.7
- **Related:** ADR-0014 (sessions), ADR-0025 (the sessions-version counter), ADR-0013 (erasure
  cascade), ADR-0028/ADR-0030 (hosting), roadmap 2.7

## Context

Every revocation the API performs existed only in Redis:

| Revocation | Key | Written by | Checked by |
|---|---|---|---|
| Every session of one parent | `auth:session-version:<parentId>` (no TTL) | `invalidateSessionsBefore` (`lib/sessions.ts`) | `isParentSessionLive` |
| One session (logout) | `revoked:token:<jti>` (8 days) | `/logout` (`routes/auth.ts`) | `isParentSessionLive`, `requireAuth` |
| One device (unpair, child erase) | `revoked:device:<deviceId>` (10 years) | `DELETE /v1/devices/:id`, `eraseChildData` | the global hook in `server.ts` and five route-local copies |

A restarted node, an evicted key, or a node whose `snapshot_retention_limit` is 0 (staging, until
this change) therefore **resurrected** the revocation:

- a parent access token that a password reset, MFA enable, logout-all or the theft response had
  killed worked again for the rest of its 7 days — `currentSessionVersion` answered `0` on a miss,
  which reads as "nothing was revoked";
- a logged-out session's access token worked again;
- an unpaired — or erased — phone's 10-year device JWT read the child's rules, location history and
  geofences, because `revoked:device:<id>` was the only thing that made it answer 401.

The values are small and the traffic is one `GET` per request, so making Redis the record was
tempting to keep. It is the wrong side of the trade: a cache may lose its contents without changing
an answer, and these three answers are security decisions about a child's data.

## Decision

The record is Postgres; Redis holds caches of it, and every cache rebuilds from the record on a miss.

1. **Parent sessions version.** `Parent.sessionVersion Int @default(0)` (migration 0024).
   `invalidateSessionsBefore` increments the column **first** and only then writes the cache; if
   either write fails the caller answers 5xx, never "revoked" (#135's rule). `currentSessionVersion`
   on a Redis miss reads the column and writes the key back with **no TTL**, even when the value is
   0 — it never returns 0 without that read. A marker with a TTL would let the next call skip the
   load while the keys it was supposed to carry are gone.
2. **Single logout keeps its meaning.** It ends this session and does **not** bump the version, so a
   second device's session survives. `RevokedToken { jti @id, parentId, expiresAt }` (index
   `parentId`) is written in the same request as `revoked:token:<jti>`, and the per-parent version
   key doubles as that parent's *loaded* marker: when step 1 finds the key missing, it also loads
   that parent's unexpired `RevokedToken` rows into Redis with their remaining TTL, **before**
   answering. Expired rows are pruned nightly (`jobs/revokedTokenPrune.ts`).
3. **Devices: the row is the record.** The global hook asks, in order: is `revoked:device:<id>`
   present (→ 401)? is `device:live:<id>` present (5-minute positive cache, → continue)? otherwise
   look the row up by primary key — absent → 401 `device_revoked` and write the tombstone; present →
   write the positive cache. Unpair and child erase `DEL device:live:<id>` and set
   `revoked:device:<id>`, and both fail closed if Redis rejects the write.
4. **ElastiCache stops cooperating with the failure** (`infra/terraform/env/elasticache.tf`):
   `maxmemory-policy = noeviction` and `snapshot_retention_limit = 1`, with the comment that said
   "cache contents are reconstructible" replaced. `scripts/check-redis-durability.mjs` gates both.

## Reasoning

- **Fail closed where the decision is made.** The read paths rebuild on a miss and the write paths
  reject. A revocation that cannot be recorded is not a revocation, so the request that performed it
  fails and the client retries; a cache write that fails on a *read* path costs one extra database
  read, not a wrong answer.
- **Small tables, not a token blacklist for everything.** A logout produces one row per ended
  session, and only for 8 days. A parent's whole-token-fleet revocation is one integer increment,
  because the counter is compared with the `sv` claim the token already carries — no per-token write
  on password reset, logout-all or the theft response, and no scan on the check path.
- **The row is the record for devices because it already exists.** Nothing has to be written on
  unpair beyond what the route already does (delete the device); "the row is gone" *is* the
  revocation, and the keys only save a lookup. That is also why a failed tombstone write cannot
  resurrect a device: the checking code sees an absent row.
- **The version key as the "loaded" marker.** One key per parent answers both questions the check
  path needs — "what version is current" and "have this parent's logout rows been restored" — so a
  cold cache costs one database round trip, not one per revoked token.

## Alternatives rejected

- **Redis-only with snapshots (keep the current design, set `snapshot_retention_limit = 1`).** The
  smallest change, and it does narrow the window. Rejected because a snapshot is a backup of a
  cache, not a record: it does not cover an eviction (`allkeys-lru` is the default and evicts
  precisely the keys that are never re-written), it does not cover a node replaced by a
  configuration change, and restoring it is an operator action measured in hours while a resurrected
  device token is valid for ten years. It also leaves the answer dependent on how the node was
  provisioned, which is what this ADR exists to remove.
- **A token blacklist table for everything** (one row per revoked `jti`, including every token of a
  logout-all). Symmetrical and easy to read, but a logout-all on a parent with many devices writes N
  rows in the request that also resets their password, and the check path gains a database read per
  request instead of only on a miss. The counter is one integer and is already in the token. Kept for
  the case it fits: single logout.
- **A Redis cluster with replicas and persistence (AOF every second).** Buys durability at the price
  of a second node for the whole keyspace and a new failure mode (a promoted replica that is behind).
  The revocation state is a few bytes per parent; Postgres already stores it and is already in the
  request path.
- **Checking the database on every request, no cache.** Correct, and the simplest to reason about —
  but it turns every rules read and every location ping into a database round trip, for an answer
  that changes on unpair. The 5-minute positive cache is the compromise: one lookup per device per
  5 minutes, and a call whose answer is "revoked" is never cached positively.
- **A `revokedAt` column on `Device` instead of deleting the row.** Would keep device metadata after
  an unpair, which ADR-0013's erasure cascade promises not to do, and would make every query that
  joins devices filter on it. Rejected as a larger change with a privacy cost.

## Costs and consequences

- **One primary-key lookup per device per 5 minutes** (the positive cache). A device that never
  uploads anything costs nothing; a device that uploads every 30 seconds costs one lookup per 5
  minutes instead of 600.
- **One database read per parent per Redis miss** — a restart, an eviction, a deploy, or the first
  request of a parent who never revoked. On a healthy cache the check path is unchanged: one `GET`.
- **Two new things to operate**: the `Parent.sessionVersion` column (additive, default 0, no
  backfill) and the `RevokedToken` table (bounded by 8 days of logouts, pruned nightly). A migration
  that runs before the new binary is harmless; a binary that runs before the migration is **not**
  covered — deploy the migration with or before the API image, which is how `prisma migrate deploy`
  already runs (`services/api/Dockerfile`).
- **A rollout window.** A revocation recorded by an old instance is Redis-only, so it can still be
  lost until every instance runs the new binary. Bounded by the 7-day access-token lifetime and, for
  devices, by nothing new (the old behaviour is what this change ends).
- **The cache can lag the record by one write under concurrency.** The version cache is written with
  `INCRBY` after the column increments, and loaded with `SET NX` on a miss, so a concurrent pair of
  revocations settles on the higher value; a set of the *lower* value would need a writer that
  ignores the column, and there is none. Recorded here because "the cache always equals the column"
  is a claim someone will want to test, and the exact guarantee is "monotonic, and equal to the
  column after any quiescent moment".
- **Not covered by this ADR:** the per-route copies of the device tombstone check (`routes/location.ts`,
  `routes/alerts.ts`, `routes/content.ts`, `routes/social.ts`, the `deviceRoutes` hook and
  `realtime/gateway.ts`) still read `revoked:device:<id>` directly. They run *behind* the global hook,
  which now decides from the row, so an evicted tombstone cannot reach them; they are defence in
  depth, and moving them onto `deviceVerdict` is a follow-up with its own tests. The WebSocket
  message loop after a ticket is accepted is likewise unchanged: the ticket route is HTTP and passes
  the hook.
- **A resurrected-session check still depends on the JWT's own `sv` claim.** A token minted before
  this change carries an `sv` that was read from Redis; if that read was wrong, this ADR does not
  retroactively repair the claim — the token is bounded by its 7-day life, and every revocation after
  the deploy is durable.

## Evidence

- `test/durable-revocation.test.ts` (11 tests): the empty-Redis parent and device cases return 200
  against the pre-fix code and 401 after it; the logout record survives a wiped cache; a single
  evicted tombstone does not resurrect a device; the positive cache is one lookup per device; both
  write paths fail closed; the prune deletes only expired rows. Each test states its mutant.
- `node scripts/check-redis-durability.mjs --selftest` (6 cases) and the same check without flags on
  `infra/terraform/env/elasticache.tf`; the pre-fix file fails it with both settings named.
- The private finding is `handfulofluck-lab/osra-security#1`. Nothing in this ADR, the code comments
  or the PR describes how to exploit it beyond "the key was the only copy".
