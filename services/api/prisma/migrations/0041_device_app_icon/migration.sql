-- Karim 23 Nov: the Parent Apps tab shows each app's real launcher icon.
-- Additive and nullable: existing rows keep null (the parent draws a letter avatar) until the
-- agent's next installed-apps report, which replaces the device's rows wholesale.
ALTER TABLE "DeviceApp" ADD COLUMN "icon" TEXT;
