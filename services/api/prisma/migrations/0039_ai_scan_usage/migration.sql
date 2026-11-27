-- Issue #890 (pricing): per-family, per-local-day scan counters, so "measured variable cost per family"
-- can be a query instead of an estimate. Additive and empty on deploy: no backfill is possible, because
-- no earlier scan was ever recorded anywhere.

-- CreateTable
CREATE TABLE "ai_scan_usage" (
    "id" TEXT NOT NULL,
    "family_id" TEXT NOT NULL,
    "day" TEXT NOT NULL,
    "scans" INTEGER NOT NULL DEFAULT 0,
    "ai_calls" INTEGER NOT NULL DEFAULT 0,

    CONSTRAINT "ai_scan_usage_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "ai_scan_usage_family_id_day_key" ON "ai_scan_usage"("family_id", "day");

-- CreateIndex
CREATE INDEX "ai_scan_usage_day_idx" ON "ai_scan_usage"("day");

-- AddForeignKey
ALTER TABLE "ai_scan_usage" ADD CONSTRAINT "ai_scan_usage_family_id_fkey" FOREIGN KEY ("family_id") REFERENCES "Family"("id") ON DELETE CASCADE ON UPDATE CASCADE;
