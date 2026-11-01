-- ADR-0034 decision 4 / A3: which build each client is.
--
-- On `Device`: the build the AGENT reported in `X-OSRA-Client`. Written only from a device-JWT request for
-- that same device, because a parent's request to a device route passes the same family check and would
-- otherwise overwrite the child's build with the parent app's.
--
-- On `ParentPushToken`: the build a PARENT's requests report. It belongs to that parent's install, not to
-- any child's device.
ALTER TABLE "Device" ADD COLUMN "clientApp" TEXT;
ALTER TABLE "Device" ADD COLUMN "clientVersion" TEXT;
ALTER TABLE "Device" ADD COLUMN "clientBuild" INTEGER;
ALTER TABLE "Device" ADD COLUMN "clientFlavour" TEXT;

ALTER TABLE "ParentPushToken" ADD COLUMN "clientApp" TEXT;
ALTER TABLE "ParentPushToken" ADD COLUMN "clientBuild" INTEGER;
ALTER TABLE "ParentPushToken" ADD COLUMN "clientFlavour" TEXT;
