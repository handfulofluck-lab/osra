-- Issue #867: the parent never sees the child phone go offline during a restart.
--
-- A phone restart takes 1–2 minutes, and the silence watch is deliberately 30 minutes (two telemetry
-- intervals, src/jobs/deviceSilence.ts) because a false `device_silent` critical is worse than a late true
-- one. The gap instead has to be REPORTED: the agent sends the wall-clock instant it booted
-- (`now - elapsedRealtime`) and the platform boot counter (`Settings.Global.BOOT_COUNT`).
--
-- The count is what decides a restart (#884 review, Fable's blocker 2): `elapsedRealtime` is monotonic but
-- `currentTimeMillis` is not, so a child moving the clock fabricates a moved instant. When both sides carry
-- a count, the counts decide and the instant only dates the alert; the instant comparison remains the
-- fallback for agents that do not send one (src/lib/bootReport.ts says so in place).
--
-- Both nullable on purpose: null is "this agent has never reported it", which an older agent never will.
-- There is no backfill — the first count-bearing report a device makes after this ships is a baseline, not
-- a restart, and the server raises nothing for it.
ALTER TABLE "Device" ADD COLUMN "lastBootAt" TIMESTAMPTZ(3);
ALTER TABLE "Device" ADD COLUMN "lastBootCount" INTEGER;
