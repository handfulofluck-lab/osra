-- G4: snapshot the first server-authored decision for each request alert.
CREATE TABLE "TimeRequestResolution" (
  "alertId" TEXT PRIMARY KEY REFERENCES "Alert" ("id") ON DELETE CASCADE ON UPDATE CASCADE,
  "action" TEXT NOT NULL,
  "minutes" INTEGER,
  "actorName" TEXT NOT NULL,
  "resolvedAt" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "TimeRequestResolution_decision"
    CHECK (("action" = 'grant' AND "minutes" IS NOT NULL AND "minutes" IN (15, 30))
        OR ("action" = 'decline' AND "minutes" IS NULL))
);
