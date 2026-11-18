# `services/api/certs/`

Public certificates only. No private key belongs here, and `scripts/check-no-service-account-keys.mjs` fails the
build if one appears.

| File | What it is | Used by |
|---|---|---|
| `rds-eu-central-1-rsa2048-g1.pem` | Amazon's single `rds-ca-rsa2048-g1` root certificate for `eu-central-1` (`CN=Amazon RDS eu-central-1 Root CA RSA2048 G1`, RSA 2048, valid until May 2061). Extracted 2026-11-18 from AWS's published regional bundle `https://truststore.pki.rds.amazonaws.com/eu-central-1/eu-central-1-bundle.pem`; X.509 SHA-256 fingerprint `3D:8B:08:A7:39:0C:9B:10:D1:90:A6:B3:49:D7:03:AE:00:BA:E4:65:83:64:33:19:C7:FA:CC:F3:E5:DC:4A:8B`, PEM file SHA-256 `6b25ace9d427f1d8a0fd8e146ebddf2384bcdb2bd1d835c620f8a7cf2895721f`. | Copied to `/app/certs/rds-eu-central-1-rsa2048-g1.pem`. Production's `DATABASE_URL` and the `db-admin` migration task name it as `sslcert` alongside `sslmode=require&sslaccept=strict`: Prisma 5.22 loads only the first PEM block of an `sslcert` file (`#919`), so `sslcert` must hold this single root rather than a multi-CA bundle. |
| `rds-global-bundle.pem` | Amazon's published root certificates for RDS, every region (114 roots). Source: `https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem`, fetched 2026-11-14, SHA-256 `90a6f1a7978a1b1b096dca6c57511ca48d3b8cf052f8e704baf358f34ea2f21b`. The earliest root in it expires in 2061. | Kept as the cross-region reference archive (and negative fixture proving `assertDatabaseTls` refuses multi-certificate `sslcert` bundles). |
| `decoy-ca.pem` | A self-signed certificate made for this repository whose key was never kept. It signs nothing. | `scripts/check-db-tls.mjs` swaps it in alone (row 2) and ahead of the real CA in a two-certificate bundle (row 4), expecting both connections to be **refused**: the proof that verification is on and that a wrong-first bundle fails. |

## Refreshing the certificates

When AWS rotates an RDS CA or a new region is adopted, fetch the regional bundle (`https://truststore.pki.rds.amazonaws.com/<region>/<region>-bundle.pem`) and `global-bundle.pem`, extract the active single root into its own one-certificate `.pem` file, update the SHA-256 fingerprints in this table, and run `pnpm --filter @familyshield/api test` (`test/database-tls.test.ts` parses every certificate, pins the `eu-central-1` `rds-ca-rsa2048-g1` fingerprint, and checks expiry).
