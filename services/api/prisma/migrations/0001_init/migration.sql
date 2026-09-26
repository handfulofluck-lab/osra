-- FamilyShield initial schema (hand-written to match prisma/schema.prisma).
-- Column types: String->TEXT, Int->INTEGER, Float->DOUBLE PRECISION, Boolean->BOOLEAN,
-- DateTime->TIMESTAMP(3), Int[]->INTEGER[], Json->JSONB.
-- FK on-delete behavior: child-scoped tables CASCADE with the child; required relations
-- NO ACTION (Prisma Restrict default); optional Alert.deviceId SET NULL.

-- CreateTable
CREATE TABLE "Family" (
    "id" TEXT NOT NULL DEFAULT gen_random_uuid(),
    "name" TEXT NOT NULL,
    "region" TEXT NOT NULL,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Family_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Parent" (
    "id" TEXT NOT NULL DEFAULT gen_random_uuid(),
    "familyId" TEXT NOT NULL,
    "email" TEXT NOT NULL,
    "passwordHash" TEXT NOT NULL,
    "displayName" TEXT NOT NULL,
    "role" TEXT NOT NULL DEFAULT 'owner',
    "mfaEnabled" BOOLEAN NOT NULL DEFAULT false,
    "mfaSecret" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Parent_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Child" (
    "id" TEXT NOT NULL DEFAULT gen_random_uuid(),
    "familyId" TEXT NOT NULL,
    "displayName" TEXT NOT NULL,
    "birthYear" INTEGER NOT NULL,
    "avatarUrl" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "Child_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Device" (
    "id" TEXT NOT NULL DEFAULT gen_random_uuid(),
    "childId" TEXT NOT NULL,
    "platform" TEXT NOT NULL,
    "model" TEXT NOT NULL,
    "osVersion" TEXT NOT NULL,
    "status" TEXT NOT NULL DEFAULT 'offline',
    "batteryPct" INTEGER NOT NULL DEFAULT 0,
    "lastSeen" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "pushToken" TEXT,

    CONSTRAINT "Device_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "RuleSet" (
    "id" TEXT NOT NULL DEFAULT gen_random_uuid(),
    "childId" TEXT NOT NULL,
    "dailyLimitMinutes" INTEGER NOT NULL DEFAULT 180,
    "weekendLimitMinutes" INTEGER NOT NULL DEFAULT 300,
    "bedtimeStart" TEXT NOT NULL DEFAULT '21:00',
    "bedtimeEnd" TEXT NOT NULL DEFAULT '07:00',
    "schoolHoursStart" TEXT NOT NULL DEFAULT '08:00',
    "schoolHoursEnd" TEXT NOT NULL DEFAULT '15:00',
    "schoolDays" INTEGER[] NOT NULL DEFAULT ARRAY[1, 2, 3, 4, 5],
    "blockedCategories" TEXT[] NOT NULL,
    "allowedDomains" TEXT[] NOT NULL,
    "blockedDomains" TEXT[] NOT NULL,
    "safeSearchEnforced" BOOLEAN NOT NULL DEFAULT true,
    "appRules" JSONB NOT NULL DEFAULT '[]',
    "routines" JSONB NOT NULL DEFAULT '[]',
    "updatedAt" TIMESTAMP(3) NOT NULL,

    CONSTRAINT "RuleSet_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "LocationPing" (
    "id" TEXT NOT NULL DEFAULT gen_random_uuid(),
    "childId" TEXT NOT NULL,
    "deviceId" TEXT NOT NULL,
    "lat" DOUBLE PRECISION NOT NULL,
    "lng" DOUBLE PRECISION NOT NULL,
    "accuracyM" DOUBLE PRECISION NOT NULL,
    "timestamp" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "LocationPing_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Geofence" (
    "id" TEXT NOT NULL DEFAULT gen_random_uuid(),
    "childId" TEXT NOT NULL,
    "label" TEXT NOT NULL,
    "lat" DOUBLE PRECISION NOT NULL,
    "lng" DOUBLE PRECISION NOT NULL,
    "radiusM" INTEGER NOT NULL,
    "notifyOnEnter" BOOLEAN NOT NULL DEFAULT true,
    "notifyOnExit" BOOLEAN NOT NULL DEFAULT true,

    CONSTRAINT "Geofence_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "Alert" (
    "id" TEXT NOT NULL DEFAULT gen_random_uuid(),
    "childId" TEXT NOT NULL,
    "deviceId" TEXT,
    "severity" TEXT NOT NULL,
    "category" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "body" TEXT NOT NULL,
    "metadata" JSONB NOT NULL DEFAULT '{}',
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "acknowledged" BOOLEAN NOT NULL DEFAULT false,

    CONSTRAINT "Alert_pkey" PRIMARY KEY ("id")
);

-- CreateTable
CREATE TABLE "ConsentRecord" (
    "id" TEXT NOT NULL DEFAULT gen_random_uuid(),
    "childId" TEXT NOT NULL,
    "parentId" TEXT NOT NULL,
    "method" TEXT NOT NULL,
    "jurisdiction" TEXT NOT NULL,
    "grantedAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "expiresAt" TIMESTAMP(3),
    "revokedAt" TIMESTAMP(3),
    "thirdPartySharing" BOOLEAN NOT NULL DEFAULT false,

    CONSTRAINT "ConsentRecord_pkey" PRIMARY KEY ("id")
);

-- CreateIndex
CREATE UNIQUE INDEX "Parent_email_key" ON "Parent"("email");

-- CreateIndex
CREATE UNIQUE INDEX "RuleSet_childId_key" ON "RuleSet"("childId");

-- CreateIndex
CREATE INDEX "LocationPing_childId_timestamp_idx" ON "LocationPing"("childId", "timestamp");

-- CreateIndex
CREATE INDEX "Alert_childId_createdAt_idx" ON "Alert"("childId", "createdAt");

-- AddForeignKey
ALTER TABLE "Parent" ADD CONSTRAINT "Parent_familyId_fkey" FOREIGN KEY ("familyId") REFERENCES "Family"("id") ON DELETE NO ACTION ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Child" ADD CONSTRAINT "Child_familyId_fkey" FOREIGN KEY ("familyId") REFERENCES "Family"("id") ON DELETE NO ACTION ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Device" ADD CONSTRAINT "Device_childId_fkey" FOREIGN KEY ("childId") REFERENCES "Child"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "RuleSet" ADD CONSTRAINT "RuleSet_childId_fkey" FOREIGN KEY ("childId") REFERENCES "Child"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "LocationPing" ADD CONSTRAINT "LocationPing_childId_fkey" FOREIGN KEY ("childId") REFERENCES "Child"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "LocationPing" ADD CONSTRAINT "LocationPing_deviceId_fkey" FOREIGN KEY ("deviceId") REFERENCES "Device"("id") ON DELETE NO ACTION ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Geofence" ADD CONSTRAINT "Geofence_childId_fkey" FOREIGN KEY ("childId") REFERENCES "Child"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Alert" ADD CONSTRAINT "Alert_childId_fkey" FOREIGN KEY ("childId") REFERENCES "Child"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "Alert" ADD CONSTRAINT "Alert_deviceId_fkey" FOREIGN KEY ("deviceId") REFERENCES "Device"("id") ON DELETE SET NULL ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ConsentRecord" ADD CONSTRAINT "ConsentRecord_childId_fkey" FOREIGN KEY ("childId") REFERENCES "Child"("id") ON DELETE CASCADE ON UPDATE CASCADE;

-- AddForeignKey
ALTER TABLE "ConsentRecord" ADD CONSTRAINT "ConsentRecord_parentId_fkey" FOREIGN KEY ("parentId") REFERENCES "Parent"("id") ON DELETE NO ACTION ON UPDATE CASCADE;
