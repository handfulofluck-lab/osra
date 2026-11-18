### Production database TLS: single `eu-central-1` RDS root CA for Prisma `sslcert` (#919, gate #637)
- The first production `db-admin` migration task failed before touching the schema (`P1011 ... self-signed certificate
  in certificate chain`) when `DATABASE_URL` carried `sslmode=require&sslaccept=strict&sslcert=/app/certs/rds-global-bundle.pem`.
  Measured against Prisma 5.22's query engine: `sslcert` loads only the **first** `-----BEGIN CERTIFICATE-----` block of
  a PEM file (`rds-global-bundle.pem` holds 114 roots with `eu-central-1`'s `rds-ca-rsa2048-g1` at index 99, and AWS's
  regional `eu-central-1-bundle.pem` places `ECC384 G1` before `RSA2048 G1`).
- The image now ships the single `CN=Amazon RDS eu-central-1 Root CA RSA2048 G1` certificate at
  `/app/certs/rds-eu-central-1-rsa2048-g1.pem` (extracted from AWS's published `eu-central-1-bundle.pem`, X.509 SHA-256
  fingerprint `3D:8B:08:A7:39:0C:9B:10:D1:90:A6:B3:49:D7:03:AE:00:BA:E4:65:83:64:33:19:C7:FA:CC:F3:E5:DC:4A:8B`, PEM
  SHA-256 `6b25ace9d427f1d8a0fd8e146ebddf2384bcdb2bd1d835c620f8a7cf2895721f`, valid until May 2061). `db_admin.tf` and
  `production-secrets.sh` point `sslcert` at that single root while keeping `sslmode=require&sslaccept=strict`;
  production's existing `osra-production/database-url` secret in Secrets Manager must also be updated out of band to
  replace `sslcert=/app/certs/rds-global-bundle.pem` with `sslcert=/app/certs/rds-eu-central-1-rsa2048-g1.pem`.
- `assertDatabaseTls` (`services/api/src/lib/databaseTls.ts`) and `verify-image.sh` now refuse any multi-certificate
  `sslcert` file before connecting, and `services/api/scripts/check-db-tls.mjs` adds row 4 proving against the live
  engine that a two-certificate bundle whose first certificate is wrong (`[decoy CA, real CA]`) is refused. Verified in
  `services/api/test/database-tls.test.ts` against both `assertDatabaseTls` and live `check-db-tls.mjs` runs over an
  in-process TLS PostgreSQL wire server; live production RDS verification runs post-merge in the production deploy lane.
