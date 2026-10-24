-- Roadmap 2.7 (osra-security#2): a digest recipient that is not a parent of the family has to confirm
-- the address before anything is sent to it, so a recipient list cannot turn the sending domain into a
-- relay to arbitrary mailboxes.
--
-- One row per (family, address). `confirmedAt` is the durable proof that the address asked for the
-- digest. `tokenHash` is the SHA-256 of the single-use 24-hour link token and `tokenExpiresAt` its
-- deadline; both are cleared when the address is confirmed, so the link is spent. A parent's own
-- address needs no row — registration already verified it.
--
-- Additive only: an API binary that predates this table never selects it, and a family with no rows
-- keeps its current recipients (parents of the family) exactly as before.
CREATE TABLE "DigestRecipient" (
  "id"             TEXT NOT NULL,
  "familyId"       TEXT NOT NULL,
  "email"          TEXT NOT NULL,
  "confirmedAt"    TIMESTAMP(3),
  "tokenHash"      TEXT,
  "tokenExpiresAt" TIMESTAMP(3),
  "createdAt"      TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT "DigestRecipient_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "DigestRecipient_familyId_email_key" ON "DigestRecipient"("familyId", "email");
CREATE UNIQUE INDEX "DigestRecipient_tokenHash_key" ON "DigestRecipient"("tokenHash");
CREATE INDEX "DigestRecipient_familyId_idx" ON "DigestRecipient"("familyId");
