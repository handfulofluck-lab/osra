-- #442 PR 3 (Play account deletion, the web link): the single-use link that `POST
-- /v1/account/deletion-request` mails and `POST /v1/account/delete/confirm` spends.
--
-- `tokenHash` is the SHA-256 of a 32-byte random token; the plaintext is only in the email. The link
-- lives 30 minutes (`expiresAt`) and is spent by one conditional update that sets `usedAt` where it is
-- still null, so two concurrent submits cannot both delete. A new request deletes the parent's earlier
-- rows, so a parent has at most one row. The FK cascades with the parent, and the account deletion
-- deletes the rows explicitly as well (`FAMILY_SCOPED_DELETES`, `PARENT_SCOPED_DELETES`).
--
-- Additive only: an API binary that predates this table never selects it.
CREATE TABLE "AccountDeletionToken" (
  "id"        TEXT NOT NULL,
  "parentId"  TEXT NOT NULL,
  "tokenHash" TEXT NOT NULL,
  "expiresAt" TIMESTAMP(3) NOT NULL,
  "usedAt"    TIMESTAMP(3),
  "createdAt" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

  CONSTRAINT "AccountDeletionToken_pkey" PRIMARY KEY ("id")
);

CREATE UNIQUE INDEX "AccountDeletionToken_tokenHash_key" ON "AccountDeletionToken"("tokenHash");
CREATE INDEX "AccountDeletionToken_parentId_idx" ON "AccountDeletionToken"("parentId");
ALTER TABLE "AccountDeletionToken" ADD CONSTRAINT "AccountDeletionToken_parentId_fkey"
  FOREIGN KEY ("parentId") REFERENCES "Parent"("id") ON DELETE CASCADE ON UPDATE CASCADE;
