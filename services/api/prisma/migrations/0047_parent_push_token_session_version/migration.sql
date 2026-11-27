-- Stamp parent push registrations with the parent's current `sessionVersion` so registrations
-- predating a session revocation cannot receive alert pushes even if best-effort row cleanup
-- (e.g. after `/v1/auth/mfa/verify` issues one-time recovery codes) encounters a transient error.

ALTER TABLE "ParentPushToken" ADD COLUMN "sessionVersion" INTEGER NOT NULL DEFAULT 0;

UPDATE "ParentPushToken" AS pt
SET "sessionVersion" = p."sessionVersion"
FROM "Parent" AS p
WHERE pt."parentId" = p."id";
