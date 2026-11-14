# `services/api/certs/`

Public certificates only. No private key belongs here, and `scripts/check-no-service-account-keys.mjs` fails the
build if one appears.

| File | What it is | Used by |
|---|---|---|
| `rds-global-bundle.pem` | Amazon's published root certificates for RDS, every region (114 roots). Source: `https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem`, fetched 2026-11-14, SHA-256 `90a6f1a7978a1b1b096dca6c57511ca48d3b8cf052f8e704baf358f34ea2f21b`. The earliest root in it expires in 2061. | The image copies it to `/app/certs/rds-global-bundle.pem`; production's `DATABASE_URL` names it as `sslcert` so Prisma checks the database's certificate chain and hostname (`src/lib/databaseTls.ts`). |
| `decoy-ca.pem` | A self-signed certificate made for this repository whose key was never kept. It signs nothing. | `scripts/check-db-tls.mjs` swaps it in for the real bundle and expects the connection to be **refused**: the proof that verification is on. |

## Refreshing the bundle

AWS adds roots when it opens a region or rotates a CA. Download the file again from the address above, replace
`rds-global-bundle.pem`, update the date and the SHA-256 in this table, and run `pnpm --filter @familyshield/api test`
(`test/database-tls.test.ts` parses every certificate and fails if one expires within two years or if the Frankfurt
and Stockholm roots are missing).
