-- ADR-0024 (F1/F2 of the #93 digest review): a claim outlives only a *permanent* refusal.
-- `failedReason` turns the claim row into a terminal record for the period; a transient failure still
-- deletes it so the next tick retries. Nullable, so existing send rows need no backfill and an older
-- API binary (which never selects this column) keeps working against it.
ALTER TABLE "DigestSend" ADD COLUMN "failedReason" TEXT;
