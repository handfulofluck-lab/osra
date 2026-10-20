-- Issue #227: repeated remove-protection attempts are one alert per window, with a count.
--
-- The child agent keeps a 5-minute window and sends `dedupeKey =
-- "<deviceId>|protection_screen_opened|<windowStartMs>"` with the running `attemptCount`. A repeat
-- key with a higher count updates this row in place and pushes no second notification; a new window
-- start is a new key and a new row. Every other alert (and #225's `device_admin_removed`) keeps
-- attemptCount = 1 and its existing duplicate-is-a-no-op behaviour.
--
-- Additive with a default: a pre-#227 API binary ignores the column; existing rows read 1.
ALTER TABLE "Alert" ADD COLUMN "attemptCount" INTEGER NOT NULL DEFAULT 1;
