-- Roadmap 3.4: installed-launchable-app inventory per device, for building app rules from the
-- apps a child actually has instead of a typed package id.
--
-- Additive only: a pre-3.4 API binary never selects the table or the two Device columns, so a
-- deploy needs no backfill and no coordinated restart. The rows are an inventory (package id,
-- launcher label, system flag) — no usage minutes, launch counts or icons — and are replaced
-- wholesale by each report from the agent. `DeviceApp` cascades with its `Device` row, and the
-- erasure cascade deletes it explicitly before the device for a countable GDPR result.
CREATE TABLE "DeviceApp" (
  "id"        TEXT NOT NULL,
  "deviceId"  TEXT NOT NULL,
  "packageId" TEXT NOT NULL,
  "label"     TEXT NOT NULL,
  "isSystem"  BOOLEAN NOT NULL DEFAULT false,
  "updatedAt" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "DeviceApp_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "DeviceApp_deviceId_packageId_key" ON "DeviceApp"("deviceId", "packageId");
CREATE INDEX "DeviceApp_deviceId_idx" ON "DeviceApp"("deviceId");
ALTER TABLE "DeviceApp" ADD CONSTRAINT "DeviceApp_deviceId_fkey"
  FOREIGN KEY ("deviceId") REFERENCES "Device"("id") ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "Device" ADD COLUMN "appsReportedAt" TIMESTAMPTZ(3);
ALTER TABLE "Device" ADD COLUMN "appsVersion" INTEGER;
