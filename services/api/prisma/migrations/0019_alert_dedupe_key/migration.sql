-- Issue #225: one device-admin deactivation must create one alert row.
--
-- The child agent sends `dedupeKey` = "<deviceId>|device_admin_removed|<disable timestamp>". The
-- expedited worker and the 60-s drain can both POST for the same event (the agent and the server
-- race), so the insert is unique per (device, category, key). Nullable and partial: alerts without
-- a key — every other producer — keep the old best-effort behaviour and are not deduplicated.
--
-- Additive only: a pre-#225 API binary never selects or writes the column.
ALTER TABLE "Alert" ADD COLUMN "dedupeKey" TEXT;

CREATE UNIQUE INDEX "Alert_deviceId_category_dedupeKey_key"
  ON "Alert"("deviceId", "category", "dedupeKey")
  WHERE "dedupeKey" IS NOT NULL;
