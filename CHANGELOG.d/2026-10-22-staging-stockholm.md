### Infra — staging's region and state coordinates move to Stockholm, `eu-north-1` (#258, ADR-0030)
- ADR-0030 recorded on 2026-10-22 that AWS's UAE region (`me-central-1`) is damaged — one zone written
  off with data loss, ECR refusing image pushes — so staging moves to Stockholm (`eu-north-1`) and
  production's first region is Frankfurt (`eu-central-1`). This is the code half of #258's move list:
  every hard-coded region now names `eu-north-1`.
- Region defaults changed: `infra/terraform/base/variables.tf` and `infra/terraform/env/variables.tf`
  (`region`), the `AWS_REGION` default in `infra/terraform/up.sh` and `down.sh`, both
  `terraform.tfvars.example` files (including the `api_image` example host), the `api_image` variable
  description, and the `aws-region` of the OIDC step in `.github/workflows/api-publish.yml`.
- State coordinates changed with it — a state bucket cannot be read from the region it does not live in:
  the `backend "s3"` block in `base/versions.tf` and `env/versions.tf` and the
  `terraform_remote_state` config in `env/remote_state.tf` now name
  `osra-terraform-state-222207908538-eu-north-1` in `eu-north-1`. Keys are unchanged
  (`staging/base/terraform.tfstate`, `staging/env/terraform.tfstate`).
- Three comments that had become false are corrected rather than left: the bucket rationale said state
  "never leaves the UAE" — it now says state stays with the stack, and records that the region changed on
  2026-10-22 (ADR-0030) leaving the old `me-central-1` bucket to be deleted with that stack; the
  ElastiCache Valkey note is dated as a `me-central-1` observation and points production at Frankfurt
  (`eu-central-1`) instead; `infra/terraform/README.md`'s title, state section, `AWS_REGION` examples, ECR
  login example, Valkey section and cost line follow, and `docs/RELEASING.md`'s ECR login example does too.
- The cost figures are **not** re-quoted: the per-item prices were taken from the previous region's list
  prices and Stockholm's differ, so `infra/terraform/README.md` says so rather than presenting 0.19/h as a
  Stockholm price.
- **Not done here, deliberately:** no state bucket exists in `eu-north-1` yet (it is created and hardened
  outside Terraform, per that README), nothing has been planned or applied, and the `me-central-1` base
  stack has not been destroyed — the order in ADR-0030 decision 2 is: create the bucket, apply base in
  `eu-north-1`, then destroy the old base. The Valkey engine lookup has not been repeated in `eu-north-1`
  either, so `redis` 7.1 is unverified in the region staging now uses. No Terraform resource changed
  semantics; `terraform fmt -check -recursive` and `validate` in both stacks are the only checks run, and
  the first real proof is the first `up.sh` against `eu-north-1`.
