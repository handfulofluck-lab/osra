-- Issue #1127 / ADR-0046: server-owned initial-setup state and audit-only held tamper events.
-- Existing paired devices were already past first setup, so backfilling completion prevents a
-- false "protected" alert and keeps their tamper behavior unchanged. Pending pairings stay incomplete.

ALTER TABLE "Device" ADD COLUMN "setupCompletedAt" TIMESTAMPTZ(3);
ALTER TABLE "Alert" ADD COLUMN "heldDuringSetup" BOOLEAN NOT NULL DEFAULT false;

UPDATE "Device"
SET "setupCompletedAt" = "pairedAt"
WHERE "pairedAt" IS NOT NULL
  AND "setupCompletedAt" IS NULL;
