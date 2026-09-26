-- Phase 3/5 additions: social-monitoring toggles + contact allowlist on RuleSet.
ALTER TABLE "RuleSet" ADD COLUMN IF NOT EXISTS "socialMonitoring" JSONB NOT NULL DEFAULT '{}';
ALTER TABLE "RuleSet" ADD COLUMN IF NOT EXISTS "contactAllowlist" TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[];
