-- Issue #221 (D1): a `locate_now` the device cannot answer must fail at the POST, not expire unseen.
--
-- Without "allow all the time" background location the agent's LocationService never starts (that
-- is #155 working as designed), so the only poll is WorkManager, which Android clamps to 15 minutes
-- plus its 5-minute flex. A Locate issued in the 10 minutes before a tick used to expire unseen.
-- The agent now reports its location grant in the existing 15-minute telemetry upload, and the
-- server can answer the parent at once when that state cannot support a background location fix.
--
-- Additive and nullable on purpose: a device that has not reported yet (or an older agent that does
-- not send `locationGrant`) reads NULL, which the command route treats as "unknown" and queues
-- normally. No backfill is possible — the grant is only knowable from the handset.
ALTER TABLE "Device" ADD COLUMN "locationGrant" TEXT;

-- D1 follow-up (Claude's review of #228): the report needs a date, because a refusal on a stale
-- grant tells a parent to fix something the child already fixed (measured on the Flip4: "allow all
-- the time" granted, a Locate four seconds later still refused). The command route trusts a report
-- only while it is younger than one telemetry period; older or undated reads NULL and queues.
ALTER TABLE "Device" ADD COLUMN "locationGrantReportedAt" TIMESTAMPTZ(3);
