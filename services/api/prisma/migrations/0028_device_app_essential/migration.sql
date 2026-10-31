-- Issue #199 item 5: the device reports whether Android treats a package as essential (dialer, HOME,
-- the agent itself). Nullable with no backfill: null means "this phone has not reported it", which the
-- parent renders exactly as it does today. A default of false would claim "not essential" for every
-- existing row until the next inventory, which is a lie about the dialer.
ALTER TABLE "DeviceApp" ADD COLUMN "essential" BOOLEAN;
