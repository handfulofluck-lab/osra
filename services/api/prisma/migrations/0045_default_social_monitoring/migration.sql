-- #1142: new and existing children need an explicit saved monitoring choice before the first scan.
-- Idempotent and limited to an empty map; every non-empty parent choice is left untouched.
UPDATE "RuleSet"
SET "socialMonitoring" = '{
  "whatsapp": true,
  "instagram": true,
  "tiktok": true,
  "snapchat": true,
  "twitter": true,
  "discord": true,
  "roblox": true,
  "line": true,
  "youtube": true,
  "telegram": true,
  "reddit": true,
  "messenger": true
}'::jsonb
WHERE "socialMonitoring" = '{}'::jsonb;
