CREATE TABLE "StagingScanOutcome" (
    "traceId" UUID PRIMARY KEY,
    "childId" TEXT NOT NULL REFERENCES "Child"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    "socialEventId" TEXT REFERENCES "SocialEvent"("id") ON DELETE SET NULL ON UPDATE CASCADE,
    "providers" JSONB NOT NULL,
    "createdAt" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX "StagingScanOutcome_socialEventId_key" ON "StagingScanOutcome"("socialEventId");
CREATE INDEX "StagingScanOutcome_childId_createdAt_idx" ON "StagingScanOutcome"("childId", "createdAt");
