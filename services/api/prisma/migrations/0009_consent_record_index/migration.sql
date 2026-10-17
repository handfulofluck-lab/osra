-- ADR-0008: the active-consent gate now runs on every device ingestion/read; index the lookup.
CREATE INDEX IF NOT EXISTS "ConsentRecord_childId_revokedAt_idx" ON "ConsentRecord"("childId", "revokedAt");
