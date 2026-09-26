-- Token hygiene (2026-09-18 handoff): per-device internal HMAC secret.
ALTER TABLE "Device" ADD COLUMN IF NOT EXISTS "internalSecret" TEXT;
