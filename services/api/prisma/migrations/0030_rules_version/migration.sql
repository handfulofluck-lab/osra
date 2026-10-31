-- Issue #475: the parent must be able to tell "saved" from "the phone has it".
--
-- `rulesVersion` starts at 1 for every ruleset, including the rows that already exist: those devices have
-- an applied version of NULL, which the parent app reads as "never reported" and shows nothing for. A
-- backfill to 0 would claim the device is behind on a version it has never been told about.
ALTER TABLE "RuleSet" ADD COLUMN "rulesVersion" INTEGER NOT NULL DEFAULT 1;
ALTER TABLE "Device" ADD COLUMN "appliedRulesVersion" INTEGER;
