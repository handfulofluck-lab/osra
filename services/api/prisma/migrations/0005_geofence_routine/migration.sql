-- Phase 6: school-geofence auto-apply binding (Feature #23).
ALTER TABLE "Geofence" ADD COLUMN IF NOT EXISTS "routineId" TEXT;
