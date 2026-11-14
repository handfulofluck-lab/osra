### Infra — a production run may not name the staging profile (osra#768)
- #765 refuses a production run with no `AWS_PROFILE`. It still allowed `OSRA_ENV=production
  AWS_PROFILE=osra-staging` — a credential that was given, and is the one belonging to the other
  environment. `up.sh` now refuses that by name, inside #765's production block.
- `scripts/check-up-production-credential.mjs` runs the real script under **bash** with stub `terraform`
  and `aws` on `PATH` (four checks, including #765's own refusal as a regression row), and its self-test
  removes the guard and shows check 2 stop passing. Wired into `workflow-lint`.
