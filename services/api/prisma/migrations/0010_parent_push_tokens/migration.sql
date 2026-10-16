-- Phase 2a: parent push-token registry for FCM/APNs alert delivery.
CREATE TABLE "ParentPushToken" (
    "id" TEXT NOT NULL,
    "parentId" TEXT NOT NULL,
    "token" TEXT NOT NULL,
    "platform" TEXT NOT NULL,
    "appVersion" TEXT,
    "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "lastSeenAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT "ParentPushToken_pkey" PRIMARY KEY ("id")
);
CREATE UNIQUE INDEX "ParentPushToken_token_key" ON "ParentPushToken"("token");
CREATE INDEX "ParentPushToken_parentId_idx" ON "ParentPushToken"("parentId");
ALTER TABLE "ParentPushToken" ADD CONSTRAINT "ParentPushToken_parentId_fkey"
    FOREIGN KEY ("parentId") REFERENCES "Parent"("id") ON DELETE CASCADE ON UPDATE CASCADE;
