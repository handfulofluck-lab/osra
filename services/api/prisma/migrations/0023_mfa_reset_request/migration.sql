-- ADR-0031: MFA reset with a family witness and a 72-hour window — the audit row and state machine.
--
-- One row per request. `state` walks requested → mailbox_confirmed → witness_passed → completed, and
-- the terminal alternatives are cancelled_by_signin / cancelled_by_link / cancelled_by_parent /
-- expired / too_many_attempts. `no_witness` (the request-time refusal, claim 7) is part of the
-- vocabulary and is never written: that refusal stores nothing, so it cannot be a row.
--
-- `codeHash` is the SHA-256 of the 8-digit device code. The plaintext exists only in the
-- `show_reset_code` DeviceCommand payload (cleared on ack, on command expiry and on the witness) and
-- is never stored here — claim 6. `familyId` is denormalised for the audit read and carries no FK,
-- matching DigestSend.
--
-- Additive only: an API binary that predates this table never selects it. The indexes answer the two
-- queries the routes and the expiry job make: "is there an open request for this parent", "which
-- mailbox-confirmed requests passed their 24-hour witness deadline", and retention by outcomeAt.
CREATE TABLE "MfaResetRequest" (
  "id"                 TEXT NOT NULL,
  "parentId"           TEXT NOT NULL,
  "familyId"           TEXT NOT NULL,
  "state"              TEXT NOT NULL DEFAULT 'requested',
  "createdAt"          TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  "emailConfirmedAt"   TIMESTAMP(3),
  "witnessKind"        TEXT,
  "witnessRef"         TEXT,
  "witnessAt"          TIMESTAMP(3),
  "windowEndsAt"       TIMESTAMP(3),
  "failedCodeAttempts" INTEGER NOT NULL DEFAULT 0,
  "codeHash"           TEXT,
  "codeExpiresAt"      TIMESTAMP(3),
  "completedAt"        TIMESTAMP(3),
  "cancelledReason"    TEXT,
  "outcomeAt"          TIMESTAMP(3),
  CONSTRAINT "MfaResetRequest_pkey" PRIMARY KEY ("id")
);
CREATE INDEX "MfaResetRequest_parentId_state_idx" ON "MfaResetRequest"("parentId", "state");
CREATE INDEX "MfaResetRequest_state_emailConfirmedAt_idx" ON "MfaResetRequest"("state", "emailConfirmedAt");
CREATE INDEX "MfaResetRequest_state_createdAt_idx" ON "MfaResetRequest"("state", "createdAt");
CREATE INDEX "MfaResetRequest_outcomeAt_idx" ON "MfaResetRequest"("outcomeAt");
ALTER TABLE "MfaResetRequest" ADD CONSTRAINT "MfaResetRequest_parentId_fkey"
  FOREIGN KEY ("parentId") REFERENCES "Parent"("id") ON DELETE CASCADE ON UPDATE CASCADE;
