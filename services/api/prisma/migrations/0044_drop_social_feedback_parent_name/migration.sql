-- #1113: Parent.displayName is the only parent-name source. This is a no-op on an empty table
-- and removes only the denormalised copy on a populated one.
-- Documented rollback restores the column but not old values:
-- ALTER TABLE "SocialEventFeedback" ADD COLUMN "parentName" TEXT;
ALTER TABLE "SocialEventFeedback" DROP COLUMN "parentName";
