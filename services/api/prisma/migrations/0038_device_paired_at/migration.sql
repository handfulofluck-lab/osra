-- Issue #790: a device is PENDING until its first accepted request.
--
-- `POST /v1/devices/pair/claims/:claimId/poll` creates the Device row the moment the parent's Allow is
-- taken, and mints the phone's per-device HMAC secret with it. Until now that row was written
-- `status: "online"`, so a phone that never proved it held the secret — a wrong key, a planted fault, a
-- bug in a new agent — stayed on the family and the parent app showed it working for 30 minutes, until
-- the silence job flipped it. A refused client cannot ask the server to drop its own row, so the state
-- has to be the server's: the row starts pending and becomes visible on the first request the API
-- accepts from it.
--
-- ADDITIVE and nullable, so a binary that predates this migration keeps working: it never writes the
-- column, and the backfill below means no device that serves a family today is read as pending.

ALTER TABLE "Device" ADD COLUMN "pairedAt" TIMESTAMPTZ(3);

-- Backfill: every row that exists when this runs has already been serving requests (the poll wrote it
-- `online` and the agents were reporting), so `lastSeen` is the honest "it proved itself" time. Without
-- this, every existing phone would vanish from its parent's device list and be deleted by
-- `jobs/pendingDevices.ts` 30 minutes after the deploy.
UPDATE "Device" SET "pairedAt" = "lastSeen" WHERE "pairedAt" IS NULL;

-- The sweep in `jobs/pendingDevices.ts` reads `pairedAt IS NULL AND lastSeen < cutoff`; that predicate is
-- narrow (a handful of rows per tick, normally none) and the table is small, so no index is added. An
-- index on a column that is null for a day's worth of abandoned claims and non-null for every real
-- device would cost write time on every pairing for a read that walks a few rows.
--
-- Folder number: 0038. `main` already carries `0036_parent_consent_events` (#878) and the unmerged #884
-- carries `0037_device_last_boot_at`, so this cannot be 0036 or 0037. Prisma orders by folder name, so a
-- gap is harmless and a collision is not — two same-numbered folders would apply in one order today and a
-- different one tomorrow.
