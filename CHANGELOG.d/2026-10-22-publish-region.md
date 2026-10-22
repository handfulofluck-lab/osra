### Staging — the image publish derives its ECR region from the repository URL instead of hardcoding it
- `.github/workflows/api-publish.yml` computed the registry host from `AWS_ECR_REPOSITORY` but asked for
  the login password in a hardcoded `me-central-1`. When the variable pointed at a repository in another
  region, `aws ecr get-login-password` returned a token for the wrong registry and `docker login` failed
  with a bare `400 Bad Request`, which reads like a broken credential rather than a mismatched region.
- The login now derives both the host and the region from the one variable (`ACCOUNT.dkr.ecr.REGION.
  amazonaws.com`), validates that shape and names the bad value if it does not match, and runs under
  `set -euo pipefail` so a failed `get-login-password` reports itself instead of the `docker login` error.
- Where this matters: the login failed exactly once the variable named a repository outside
  `me-central-1`, and #258 has reopened which region staging belongs in. A login that is not tied to one
  region is a prerequisite for testing that, and it does not change behaviour for a well-formed variable.
- Not verified end to end here: the step only runs on `main` under the publish role, so the first proof is
  a dispatched run.
