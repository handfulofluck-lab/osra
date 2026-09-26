-- Fix child-erasure cascade: LocationPing.deviceId must cascade with its device,
-- otherwise deleting a child that has location pings fails with P2003.
ALTER TABLE "LocationPing" DROP CONSTRAINT "LocationPing_deviceId_fkey";
ALTER TABLE "LocationPing" ADD CONSTRAINT "LocationPing_deviceId_fkey"
  FOREIGN KEY ("deviceId") REFERENCES "Device"("id") ON DELETE CASCADE ON UPDATE CASCADE;
