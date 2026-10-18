-- ADR-0017: the digest is due at the family's local hour.
-- `region` is a market (US/EU/UK/OTHER), not a country, so there is nothing to backfill from: every
-- existing family starts at UTC and the 3.x app setting is the real source (see the ADR amendment).
ALTER TABLE "Family" ADD COLUMN "timezone" TEXT NOT NULL DEFAULT 'UTC';

CREATE TABLE "DigestSend" (
    "id" TEXT NOT NULL,
    "familyId" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "period" TEXT NOT NULL,
    "sentAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "DigestSend_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "DigestSend_familyId_kind_period_key" ON "DigestSend"("familyId", "kind", "period");
CREATE INDEX "DigestSend_familyId_idx" ON "DigestSend"("familyId");
