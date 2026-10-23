### API — revocations are stored in Postgres and Redis is only a cache (roadmap 2.7)
- Every revocation the API performs now has a durable record, and Redis holds a cache of it: the
  parent's sessions version is `Parent.sessionVersion`, a single logout is a `RevokedToken` row, and
  an unpaired device is the absence of its `Device` row. Before this, a restarted or evicted
  ElastiCache node — or `snapshot_retention_limit = 0` — brought all three back to life: a revoked
  parent session worked again, and an unpaired phone's 10-year device token read the child's rules,
  location history and geofences.
- The cache now rebuilds from the record: a Redis miss reads the column and loads that parent's
  unexpired logout rows before anything answers, so `0` is never returned without that read. A
  device is decided by its row when both the tombstone and the 5-minute positive cache miss.
- The writes fail closed: a revocation that cannot be recorded in the database, or published to the
  cache, answers 5xx instead of reporting success. `GET`-path cache writes stay best-effort — the
  row already answered the question.
- Staging ElastiCache: the parameter group pins `maxmemory-policy = noeviction` (the default
  `allkeys-lru` evicts exactly the revocation keys) and `snapshot_retention_limit` goes from 0 to 1.
  `scripts/check-redis-durability.mjs` gates both settings, with a self-test for each rule.
- Costs, accepted in ADR-0032: one primary-key device lookup per device per 5 minutes, and one
  database read per parent per Redis miss (a restart, an eviction, or the first request after a
  deploy). One extra migration (`0024_durable_revocation`) adds the column and the table; it is
  additive, so no coordinated restart and no backfill.
- Verified by `test/durable-revocation.test.ts` (11 tests): each names the mutant that makes it fail,
  and the empty-Redis cases were re-run against the pre-fix code, where they returned 200. Not run
  for this change: `qa-probe.mjs` and `e2e.mjs`, because the shared stack was in use by another
  agent's run (see the PR).
