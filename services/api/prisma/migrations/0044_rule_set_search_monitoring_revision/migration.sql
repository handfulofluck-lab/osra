-- osra-security#59: server-authoritative opt-in revision bumped on searchMonitoring changes
ALTER TABLE "RuleSet" ADD COLUMN "searchMonitoringRevision" INTEGER NOT NULL DEFAULT 0;
UPDATE "RuleSet" SET "searchMonitoringRevision" = 1 WHERE "searchMonitoring" = true;
