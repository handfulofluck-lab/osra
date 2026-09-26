-- Phase 6: multi-parent invites (Feature #13) — invited parents carry free-text permission tags.
ALTER TABLE "Parent" ADD COLUMN IF NOT EXISTS "permissions" TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[];
