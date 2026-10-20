-- Claude's review of #242: geofence alerts stored the child's exact lat/lng in `metadata`, and Alert
-- rows are deleted only by erasure — so those coordinates would have outlived the 30-day location
-- window this release introduces, contradicting the consent copy that says location is kept 30 days.
--
-- The producer no longer writes them (routes/location.ts), and the fence's own position is already in
-- `Geofence`, so nothing reads them. This scrubs the rows written before the change; it removes only
-- the two coordinate keys and leaves geofenceId/label intact.
UPDATE "Alert"
SET metadata = metadata - 'lat' - 'lng'
WHERE category = 'geofence' AND metadata IS NOT NULL;
