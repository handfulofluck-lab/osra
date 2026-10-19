-- ADR-0023 Option A: one-time MFA recovery codes.
--
-- Ten rows per batch, each the SHA-256 of a 16-character Crockford base32 code (80 bits). The
-- plaintext is returned once by POST /v1/auth/mfa/verify or /v1/auth/mfa/recovery-codes and is never
-- stored or logged. `usedAt` is the one-time-use gate (`updateMany ... where usedAt IS NULL`); the
-- used row is kept as the record that the batch was spent, and recovery deletes its siblings.
--
-- Additive only: an API binary that predates this table never selects it, so a deploy needs no
-- backfill and no coordinated restart. No backfill is possible in the other direction either — codes
-- cannot be derived from the TOTP secret, so an account that enabled MFA before this ships gets its
-- first batch when it next calls /mfa/recovery-codes or re-verifies an enrolment.
CREATE TABLE "ParentMfaRecoveryCode" (
  "id"        TEXT NOT NULL,
  "parentId"  TEXT NOT NULL,
  "codeHash"  TEXT NOT NULL,
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "usedAt"    TIMESTAMP(3),
  CONSTRAINT "ParentMfaRecoveryCode_pkey" PRIMARY KEY ("id")
);
CREATE INDEX "ParentMfaRecoveryCode_parentId_usedAt_idx" ON "ParentMfaRecoveryCode"("parentId", "usedAt");
ALTER TABLE "ParentMfaRecoveryCode" ADD CONSTRAINT "ParentMfaRecoveryCode_parentId_fkey"
  FOREIGN KEY ("parentId") REFERENCES "Parent"("id") ON DELETE CASCADE ON UPDATE CASCADE;
