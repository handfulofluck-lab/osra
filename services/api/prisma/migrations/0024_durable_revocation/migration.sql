-- ADR-0032 / roadmap 2.7: revocations live in Postgres, Redis is only a cache.
--
-- Until now every revocation existed only in Redis: the parent's sessions version
-- (`auth:session-version:<parentId>`), a single logout (`revoked:token:<jti>`) and an unpaired
-- device (`revoked:device:<deviceId>`). A restarted or evicted node brought all three back to life —
-- a revoked parent session worked again and an unpaired phone's 10-year device token read the
-- child's rules, location history and geofences. This migration adds the two durable records the
-- API now writes first: `Parent.sessionVersion` and `RevokedToken`. The device side needs no table —
-- the `Device` row's existence is the record, so deleting it is the revocation.
--
-- ADDITIVE ONLY, with defaults, so an API binary that predates this migration keeps working and the
-- deploy needs no coordinated restart and no backfill:
--   * `sessionVersion` defaults to 0, which is exactly what a Redis miss used to mean
--     ("nothing was revoked"), so every existing parent starts at the truth with no UPDATE.
--   * `RevokedToken` is a new table no old binary selects; a logout recorded by an old instance is
--     therefore not durable until every instance runs this binary. Rolling that forward is the
--     deploy, not the migration: sessions revoked before the deploy that could still be presented
--     are bounded by the 7-day access-token lifetime.
--
-- The index answers the two reads this table exists for: the miss-load in
-- `lib/sessions.ts` ("this parent's unexpired revocations") and the nightly prune by `expiresAt`
-- (which walks the whole table, so no second index is needed for it).
ALTER TABLE "Parent" ADD COLUMN "sessionVersion" INTEGER NOT NULL DEFAULT 0;

CREATE TABLE "RevokedToken" (
  "jti"       TEXT NOT NULL,
  "parentId"  TEXT NOT NULL,
  "expiresAt" TIMESTAMP(3) NOT NULL,
  CONSTRAINT "RevokedToken_pkey" PRIMARY KEY ("jti")
);
-- No FK to "Parent": `parentId` is denormalised like "DigestSend"."familyId", because the row is
-- the record of a revocation and must be deletable only by its own expiry — never by a cascade that
-- a future parent-deletion path could trigger while a token it revoked is still presentable.
CREATE INDEX "RevokedToken_parentId_idx" ON "RevokedToken"("parentId");
