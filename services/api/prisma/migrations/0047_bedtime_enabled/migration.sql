-- Issue #1172: Bedtime gets an on/off switch. Existing children keep what they have (on); a new child
-- is created with Bedtime off and no school days, so no routine runs until a parent turns it on.

ALTER TABLE "RuleSet" ADD COLUMN "bedtimeEnabled" BOOLEAN NOT NULL DEFAULT true;
