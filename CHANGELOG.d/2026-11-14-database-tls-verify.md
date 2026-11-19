### API — production checks the database's certificate, and proves it (#766 item 3, gate #637)
- The image now carries Amazon's RDS root certificates at `/app/certs/rds-global-bundle.pem` (public certificates,
  read-only to the API's user). `services/api/certs/README.md` says where the file comes from and how to refresh it.
- With `DATABASE_TLS_VERIFY=required` the API refuses to start unless `DATABASE_URL` carries
  `sslmode=require&sslaccept=strict&sslcert=<bundle>`. That is the only form Prisma 5.22 verifies with: measured
  against PostgreSQL 16 behind a private CA, `sslmode=verify-full&sslrootcert=…` connects even when the CA is the
  wrong one, and no error says so. The refusal names what is missing and never prints the URL, which holds the
  password. Unset, nothing changes: staging and development are untouched.
- `services/api/scripts/check-db-tls.mjs` is the evidence for the security gate. Run where the API runs, it connects
  with the real URL, then expects a refusal with a decoy CA and with no CA at all, and exits 1 if either connects.
- 28 tests in `test/database-tls.test.ts`, each refusal with the mutant it kills; `verify-image.sh` checks the bundle
  and the boot refusal inside the built image.
