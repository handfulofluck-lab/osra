### Staging — the image publish derives its ECR region from the repository URL instead of hardcoding it
- `.github/workflows/api-publish.yml` computed the registry host from `AWS_ECR_REPOSITORY` but asked for
  the login password in a hardcoded `me-central-1`. When the variable pointed at a repository in another
  region, `aws ecr get-login-password` returned a token for the wrong registry and `docker login` failed
  with a bare `400 Bad Request`, which reads like a broken credential rather than a mismatched region.
- The login now derives both the host and the region from the one variable (`ACCOUNT.dkr.ecr.REGION.
  amazonaws.com`), so a push can only ever authenticate to the registry it is about to write to.
- Needed by the ECR replication experiment on #258: it is the only way to dispatch a publish into
  `eu-north-1` without a matching hardcoded edit.
- Not verified end to end here: the step only runs on `main` under the publish role, so the first proof
  is a dispatched run.
