-- Phase 2c (ADR-0013): usage rollup tables. Time columns are TIMESTAMPTZ so raw comparisons cannot
-- depend on the session time zone (issue #53); `day` is a DATE in UTC.
CREATE TABLE "AppUsageDaily" (
  "id"        TEXT NOT NULL,
  "childId"   TEXT NOT NULL,
  "deviceId"  TEXT NOT NULL DEFAULT '',
  "day"       DATE NOT NULL,
  "app"       TEXT NOT NULL,
  "minutes"   INTEGER NOT NULL DEFAULT 0,
  "updatedAt" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "AppUsageDaily_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "AppUsageDaily_childId_deviceId_day_app_key" ON "AppUsageDaily"("childId", "deviceId", "day", "app");
CREATE INDEX "AppUsageDaily_childId_day_idx" ON "AppUsageDaily"("childId", "day");

CREATE TABLE "WebVisit" (
  "id"       TEXT NOT NULL,
  "childId"  TEXT NOT NULL,
  "deviceId" TEXT,
  "ts"       TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "domain"   TEXT NOT NULL,
  "url"      TEXT NOT NULL DEFAULT '',
  "blocked"  BOOLEAN NOT NULL DEFAULT false,
  "category" TEXT NOT NULL DEFAULT '',
  CONSTRAINT "WebVisit_pkey" PRIMARY KEY ("id")
);
CREATE INDEX "WebVisit_childId_ts_idx" ON "WebVisit"("childId", "ts");
