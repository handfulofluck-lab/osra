-- Plan 2.7: who allowed or refused which phone when it asked to pair (osra-security#3 PR 2).
-- CreateTable
CREATE TABLE "PairingDecision" (
    "id" TEXT NOT NULL,
    "familyId" TEXT NOT NULL,
    "childId" TEXT NOT NULL,
    "parentId" TEXT NOT NULL,
    "claimId" TEXT NOT NULL,
    "decision" TEXT NOT NULL,
    "platform" TEXT NOT NULL,
    "model" TEXT NOT NULL,
    "createdAt" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "PairingDecision_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE INDEX "PairingDecision_familyId_createdAt_idx" ON "PairingDecision"("familyId", "createdAt");

-- CreateIndex
CREATE INDEX "PairingDecision_childId_idx" ON "PairingDecision"("childId");

-- AddForeignKey
ALTER TABLE "PairingDecision" ADD CONSTRAINT "PairingDecision_childId_fkey" FOREIGN KEY ("childId") REFERENCES "Child"("id") ON DELETE RESTRICT ON UPDATE CASCADE;
