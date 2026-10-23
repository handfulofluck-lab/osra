### Infra — a base apply from a clone without `terraform.tfvars` refuses, and cannot destroy the certificate or the publish path (#337)
- **The incident this prevents already happened.** Base state is shared in S3, and most of `base` is `count`-gated on
  variables that live in a **gitignored** `terraform.tfvars`. Applied from a fresh clone without that file, the counts
  evaluate to zero, so `terraform apply` **destroys** what is there — and it looks exactly like a first-time apply. On
  2026-10-23 that deleted the validated `api.staging.osratech.com` certificate
  (`DeleteCertificate` 12:57:59Z, `08320165-…`). The damage was one certificate because the OIDC provider did not exist
  yet; with the publish path in place the same command would have removed the provider and `osra-staging-publish` too.
- **Three guards, all in this PR:**
  - `up.sh` **refuses** before it applies anything — and before it writes `.session-start`, so a refused run cannot
    corrupt a later session's cost clock. The refusal names the file, the consequence and how to fill it in.
  - `prevent_destroy` on the certificate, the GitHub OIDC provider and the `osra-staging-publish` role: a future
    `count -> 0` is an error instead of a deletion.
  - Between base and env, `up.sh` checks `publish_role_arn`. Empty is a warning with the consequence spelled out (an
    image publish will fail with an OIDC error that names GitHub) rather than a silent proceeding.
- **Tested against the incident state itself:** in a worktree with no `terraform.tfvars` — the exact state that deleted
  the certificate — `./infra/terraform/up.sh -auto-approve` exits **1**, prints the refusal, and writes no
  `.session-start`. `sh -n` clean; `terraform validate` clean on base with the example tfvars.
