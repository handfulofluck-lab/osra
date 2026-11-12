-- ADR-0037 PR B3: rules on iPhone app groups, by the group id the phone reported in its capability report.
-- `[{ "groupId": "<uuid>", "action": "block" }]`; an empty list for every existing ruleset.
ALTER TABLE "RuleSet" ADD COLUMN "appGroupRules" JSONB NOT NULL DEFAULT '[]';
