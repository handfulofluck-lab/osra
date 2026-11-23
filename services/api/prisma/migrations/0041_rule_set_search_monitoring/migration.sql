-- ADR-0039 / osra-security#45: default-off opt-in flag for search query capture
ALTER TABLE "RuleSet" ADD COLUMN "searchMonitoring" BOOLEAN NOT NULL DEFAULT false;
