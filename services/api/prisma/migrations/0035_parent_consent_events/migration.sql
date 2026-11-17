-- ADR-0043 D2 / #846 part A step 2: one append-only row per consent act by an account holder.
--
-- Additive only: a new table and its two constraints. Nothing existing is altered, so a deployment that
-- rolls back the code can leave the table in place without changing how anything else behaves.
--
-- No IP address and no device id, on purpose: the row is the proof of what wording was shown and agreed
-- to, not a record of where the parent was. Rows are append-only — withdrawal of the terms is account
-- deletion, which cascades from `Parent`.
CREATE TABLE "parent_consent_events" (
  "id" TEXT NOT NULL,
  "parent_id" TEXT NOT NULL,
  "purpose" TEXT NOT NULL,
  "action" TEXT NOT NULL,
  "text_version" TEXT NOT NULL,
  "document_version" TEXT,
  "locale" TEXT NOT NULL,
  "text_hash" CHAR(64) NOT NULL,
  "surface" TEXT NOT NULL,
  "client_version" TEXT,
  "created_at" TIMESTAMPTZ(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CONSTRAINT "parent_consent_events_pkey" PRIMARY KEY ("id"),
  CONSTRAINT "parent_consent_events_parent_id_fkey"
    FOREIGN KEY ("parent_id") REFERENCES "Parent"("id") ON DELETE CASCADE ON UPDATE CASCADE
);

CREATE INDEX "parent_consent_events_parent_id_purpose_idx"
  ON "parent_consent_events"("parent_id", "purpose");
