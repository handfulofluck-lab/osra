### Infra — a separate `ml-training` Terraform root for training OSRA's own model (#824)
- `infra/terraform/ml-training` has its own state key, so a training change never rides in a signed API plan. It
  creates a private, KMS-encrypted bucket that expires everything after 30 days, a role only SageMaker can assume
  (read `input/`, write `output/` and `checkpoints/`, nothing else), and a US$100 budget alert that must name at
  least one address. No compute, no real child data (ADR-0033).
- CI validates the root and runs a mocked test that pins the bucket's allow list, the role's two unscoped
  statements and the trust policy.
