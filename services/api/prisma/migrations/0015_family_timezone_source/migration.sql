-- ADR-0020: record where a family's timezone came from, so a device fill can never overwrite a
-- parent's explicit choice. Existing rows are `default`: their UTC value was never chosen by anyone.
ALTER TABLE "Family" ADD COLUMN "timezoneSource" TEXT NOT NULL DEFAULT 'default';
