### Infra — `up.sh` refuses production without a production credential (osra-security#27)
- `up.sh` defaults `AWS_PROFILE` to the staging profile, and a production run passes
  `-var-file=production.tfvars` through `"$@"` like any other argument. The natural way to run production
  was therefore with whatever key the shared Windows PC holds — a long-lived staging access key — and the
  deploy role it assumes reaches the database password, the JWT signing secret and the vault key, all
  three of which live in Terraform state (Fable's review of the production Terraform).
- The script now refuses, before it reads anything, when the run names production and `AWS_PROFILE` is
  unset or `osra-staging`. The first rule was written down and had nothing under it; this is the something.
- `scripts/check-up-production-guard.mjs` runs the real script with a controlled environment (4 checks)
  and its self-test removes the guard from a copy and shows check 1 stop passing. Wired into
  `workflow-lint`, because a guard no job runs is the shape this repository keeps finding.
