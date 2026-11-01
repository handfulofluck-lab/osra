-- ADR-0034 PR 1a: the capability report a device sends inside its telemetry upload and its pair claim.
--
-- `capabilities` is the DeviceCapabilitiesV1 object, validated by a `.strict()` schema with a 4 KB cap
-- (amendment A2), so the column holds only enum keys and enum values. `capabilitiesReportedAt` is the
-- SERVER's receipt time (A4) — never a timestamp from inside the object, which a modified agent could
-- use to keep a report "fresh" forever.
--
-- Both nullable: a device that has never reported is "unknown", never "missing". An upload without the
-- field leaves the stored report alone, so an old agent cannot erase what a newer one said.
ALTER TABLE "Device" ADD COLUMN "capabilities" JSONB;
ALTER TABLE "Device" ADD COLUMN "capabilitiesReportedAt" TIMESTAMPTZ(3);
