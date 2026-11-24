ALTER TABLE "SocialEvent"
    ADD COLUMN "modelVersion" TEXT,
    ADD COLUMN "lang" TEXT,
    ADD COLUMN "topCategory" TEXT,
    ADD COLUMN "topScore" DOUBLE PRECISION,
    ADD COLUMN "cutoff" DOUBLE PRECISION,
    ADD COLUMN "path" TEXT;

ALTER TABLE "SocialEvent"
    ADD CONSTRAINT "SocialEvent_childId_fkey" FOREIGN KEY ("childId") REFERENCES "Child"("id") ON DELETE CASCADE ON UPDATE CASCADE;

CREATE TABLE "SocialEventFeedback" (
    "id" TEXT NOT NULL,
    "socialEventId" TEXT NOT NULL,
    "parentId" TEXT NOT NULL,
    "verdict" TEXT NOT NULL,
    "parentName" TEXT NOT NULL,
    "firstVotedAt" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "lastChangedAt" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "changeCount" INTEGER NOT NULL DEFAULT 0,
    "modelVersion" TEXT,
    "lang" TEXT,
    "topCategory" TEXT,
    "topScore" DOUBLE PRECISION,
    "cutoff" DOUBLE PRECISION,
    "path" TEXT,
    "severity" TEXT,

    CONSTRAINT "SocialEventFeedback_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "SocialEventFeedback_socialEventId_fkey" FOREIGN KEY ("socialEventId") REFERENCES "SocialEvent"("id") ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT "SocialEventFeedback_parentId_fkey" FOREIGN KEY ("parentId") REFERENCES "Parent"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE UNIQUE INDEX "SocialEventFeedback_socialEventId_parentId_key" ON "SocialEventFeedback"("socialEventId", "parentId");
CREATE INDEX "SocialEventFeedback_parentId_idx" ON "SocialEventFeedback"("parentId");
