### Docs — three traps that cost a staging session start, recorded in `docs/TESTING.md` §6 (#330)
- **A publish that fails on OIDC is usually missing local state, not a broken workflow.** `base/terraform.tfvars`
  is gitignored, so a fresh clone leaves `github_repo`/`owner_id`/`repo_id` empty and `base/oidc.tf` creates
  neither the provider nor the publish role. The row gives the first check (`aws iam list-open-id-connect-providers`
  → empty), the fix, and the reason the trust pins one exact subject rather than a wildcard.
- **A healthy stack that refuses every request is the allowlist.** In non-release mode `allowed_cidrs` cannot be
  `0.0.0.0/0` (`env/ecs.tf:173`), and a home connection's address moved twice in 40 minutes on 2026-10-23 — so a
  phone row needs release mode with a certificate. The row says to check `describe-target-health` before blaming
  the application, because healthy targets mean the block is the network, not the service.
- **`MSYS_NO_PATHCONV=1` breaks `up.sh`.** Exported for the AWS CLI, it also stops Git Bash converting the POSIX
  path handed to the native `terraform.exe`, which then cannot resolve `-chdir`. Scope it per command.

No code changes; `docs/TESTING.md` only. The rows are in the §6 table, beside the other traps, not appended below it.
