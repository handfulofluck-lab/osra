### Infra — the API image is published to ECR over GitHub OIDC, with no long-lived AWS key
- `.github/workflows/api-publish.yml` (`workflow_dispatch` only) builds the ARM64 image on GitHub's
  arm64 runner and pushes `<repo>:<12-character commit sha>` to `osra-staging/api`. There is no `:latest`
  and the repository is IMMUTABLE, so a tag always names exactly one image.
  No AWS credential is stored in Actions: the job exchanges a GitHub OIDC token for a role
  (`sts:AssumeRoleWithWebIdentity`), which is the deploy access ADR-0028 §8 asks for.
- The role `osra-staging-publish` (`infra/terraform/base/oidc.tf`) trusts only the `main` branch and
  the `staging-publish` environment of `handfulofluck-lab/osra`, with audience `sts.amazonaws.com` —
  in the plain subject form and in the `@owner-id`/`@repo-id` form GitHub uses for repositories
  created after 2026-07-15 (this one was created 2026-09-26). Its
  inline policy grants `ecr:GetAuthorizationToken` plus `BatchCheckLayerAvailability`,
  `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`, `BatchGetImage` and
  `DescribeImages` on the `osra-staging/api` repository only — no `ecr:*`, no other service.
- `github_repo` (new variable, default `""`) creates the OIDC provider and the role; with it empty,
  `base` is unchanged for anyone not publishing from Actions. New output `publish_role_arn`.
- Publishing needs two repository variables, set once after `base` is applied: `AWS_ECR_REPOSITORY`
  and `AWS_PUBLISH_ROLE_ARN`, read from base's `ecr_repository_url` and `publish_role_arn` outputs,
  because Actions cannot read Terraform state. The workflow's first step prints the exact
  `gh variable set` command when either is unset.
- There is no `latest` and the repository is IMMUTABLE: the tag is the 12-character commit sha, so a
  re-run on the same commit fails with "tag already exists" rather than replacing the image that sha
  names. `env/api_image` pins that sha, because a rebuild under a moving tag changes nothing the ECS
  task definition can see.
- Not verified here: no `terraform apply` was run, so the OIDC provider, the role and a first
  end-to-end publish are unexercised. `terraform fmt` and `validate` pass on `base`; the workflow was
  parsed as YAML and accepted by `scripts/check-workflows.mjs --strict`.
