### Infra — the account id is a placeholder in prose and literal only where the backend needs it (#337)
- `infra/terraform/README.md`, `CHANGELOG.d/2026-10-22-staging-stockholm.md` and the comment in
  `infra/terraform/base/versions.tf` now write the state bucket as `osra-terraform-state-<account-id>-…` instead
  of the real account. The README's own rule — *"the examples use `<account-id>` placeholders, never the real
  account"* — was disprovable in one command before this, which teaches a reader to distrust the rest of the file.
- **The three `backend` bucket lines stay literal** (`base/versions.tf`, `env/versions.tf`,
  `env/remote_state.tf`): Terraform must resolve them, so a redacted bucket name there is a broken command, not a
  private one. The README now names all three exceptions, because a rule that misses one file invites someone to
  "fix" the missing one.
- `docs/QA/DISCUSSION-LOG.md` keeps what it recorded and gains **no note**: it is append-only, and annotating a
  redaction points at the value it removes.
- An AWS account id is not a credential — it is in every ARN, and in the ECR hostname a client resolves — so this
  is a consistency fix, not an incident. `terraform validate` is clean; the only `.tf` line that changes is a
  comment.
