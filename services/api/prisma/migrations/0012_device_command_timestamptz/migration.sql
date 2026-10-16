-- Issue #53: DeviceCommand time columns were TIMESTAMP WITHOUT TIME ZONE while the queue's raw SQL
-- compared them to NOW() (timestamptz). On any non-UTC database session the naive value was read in
-- local wall-clock time, so every fresh command was already "expired". Prisma stores naive values
-- as UTC, hence the USING clause.
ALTER TABLE "DeviceCommand"
  ALTER COLUMN "createdAt"   TYPE TIMESTAMPTZ(3) USING "createdAt"   AT TIME ZONE 'UTC',
  ALTER COLUMN "expiresAt"   TYPE TIMESTAMPTZ(3) USING "expiresAt"   AT TIME ZONE 'UTC',
  ALTER COLUMN "deliveredAt" TYPE TIMESTAMPTZ(3) USING "deliveredAt" AT TIME ZONE 'UTC',
  ALTER COLUMN "ackedAt"     TYPE TIMESTAMPTZ(3) USING "ackedAt"     AT TIME ZONE 'UTC';
