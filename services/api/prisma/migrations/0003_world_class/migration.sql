-- World-class features persistence (SPEC-ADDENDUM-WORLD-CLASS.md).
CREATE TABLE IF NOT EXISTS "ActivityEvent" (
    id TEXT NOT NULL,
    "childId" TEXT NOT NULL,
    "deviceId" TEXT,
    ts TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    type TEXT NOT NULL,
    payload JSONB NOT NULL DEFAULT '{}',
    CONSTRAINT "ActivityEvent_pkey" PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS "ActivityEvent_childId_ts_idx" ON "ActivityEvent"("childId", ts);

CREATE TABLE IF NOT EXISTS "SocialEvent" (
    id TEXT NOT NULL,
    "childId" TEXT NOT NULL,
    app TEXT NOT NULL,
    contact TEXT NOT NULL DEFAULT '',
    severity TEXT NOT NULL DEFAULT 'warning',
    "previewCipher" TEXT NOT NULL DEFAULT '',
    "concernTypes" TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "SocialEvent_pkey" PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS "SocialEvent_childId_createdAt_idx" ON "SocialEvent"("childId", "createdAt");

CREATE TABLE IF NOT EXISTS "FamilyInvite" (
    id TEXT NOT NULL,
    "familyId" TEXT NOT NULL,
    email TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'co-parent',
    permissions TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    status TEXT NOT NULL DEFAULT 'pending',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "FamilyInvite_pkey" PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS "FamilyInvite_familyId_idx" ON "FamilyInvite"("familyId");

CREATE TABLE IF NOT EXISTS "DigestPrefs" (
    "familyId" TEXT NOT NULL,
    "dailyEmail" BOOLEAN NOT NULL DEFAULT true,
    "weeklyEmail" BOOLEAN NOT NULL DEFAULT true,
    "pushEnabled" BOOLEAN NOT NULL DEFAULT true,
    emails TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    CONSTRAINT "DigestPrefs_pkey" PRIMARY KEY ("familyId")
);

ALTER TABLE "RuleSet" ADD COLUMN IF NOT EXISTS "alwaysAllowedApps" TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[];
ALTER TABLE "RuleSet" ADD COLUMN IF NOT EXISTS "bonusMinutesToday" INTEGER NOT NULL DEFAULT 0;

-- Optional server-side install-approval queue (Feature #8); alert category carries events too.
CREATE TABLE IF NOT EXISTS "InstallRequest" (
    id TEXT NOT NULL,
    "childId" TEXT NOT NULL,
    "packageId" TEXT NOT NULL,
    "appName" TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'pending',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "InstallRequest_pkey" PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS "InstallRequest_childId_idx" ON "InstallRequest"("childId");
