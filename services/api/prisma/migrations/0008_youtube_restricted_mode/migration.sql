-- AlterTable
ALTER TABLE "RuleSet" ADD COLUMN IF NOT EXISTS "youtubeRestrictedMode" TEXT NOT NULL DEFAULT 'strict';
