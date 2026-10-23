### Tooling — a pre-session check that says what a staging session is missing, before it spends (#337)
- **Where the guards left a gap.** #339 made `up.sh` refuse without `base/terraform.tfvars` and put `prevent_destroy` on
  the certificate, the OIDC provider and the publish role. That covers the destructive path. It does not answer the
  question a person actually asks before a session — *will this clone be able to do what I need?* — and the two failures
  that cost 2026-10-23 its first hour (a missing tfvars, then an empty `publish_role_arn` surfacing as an OIDC error that
  named GitHub) both looked like something else.
- **`scripts/check-staging-prereqs.mjs`** answers it in one command: `base/terraform.tfvars` present, the publish role
  resolvable, and `env/api_image` naming a tag that is actually in ECR. Three rules, each naming the consequence rather
  than the symptom.
- **The decision is pure** (`stagingProblems(observed)`) so it is tested without an account, with one fixture per rule and
  a passing control. Mutants measured, one per rule: disable rule 1, 2 or 3 and exactly its own case fails (`4/5`); the
  other four still pass, which is what makes each case a test of its rule and not of the suite.
- **Environment problems are not findings:** no `aws` CLI or no usable credentials exits **2** with a named reason, the
  same shape `check-verified-gate-signers.mjs` uses, so a broken environment cannot read as a broken session.
- **Verified against the real account** (`osra-staging`, `eu-north-1`): exit **0**, "ready" with the tfvars present; move
  the file away and it exits **1** naming the destroy risk. That is the same state that deleted the certificate.

- **Two defects from Claude's review, both measured before and after the fix.** (1) *Any* AWS failure that was not a
  credential error was reported as "no publish_role_arn", exit 1 — so a bad profile, `AccessDenied` or a network error
  read as a missing role, which is the misleading-symptom failure this script exists to prevent. Only "not found"
  (`NoSuchEntity`) is a finding now; everything else exits **2** naming the first stderr line, and the classifier is a
  pure function with four fixtures (a `NoSuchEntity`, a network error, `AccessDenied`, a missing CLI). Measured after the
  fix: `AWS_PROFILE=no-such-profile` → `EXIT=2`, `ENV: aws failed: … The config profile (no-such-profile) could not be
  found`. (2) A clone under a path containing a space reported the tfvars missing while it was present, because
  `new URL(...).pathname` is percent-encoded; now `fileURLToPath`. Measured on a copy under `…/sp test/` with the file
  present: `EXIT=0`, "ready".
- **Wired in:** `workflow-lint.yml` runs `--selftest` (6 cases), and `infra/terraform/README.md` puts the command first in
  *Everyday use*, with what exit 1 and exit 2 mean.
