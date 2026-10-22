# OSRA staging infrastructure — AWS, UAE (`me-central-1`)

Terraform for the staging deployment of the API service, one independent regional stack as
[ADR-0028](../../docs/adr/0028-hosting-regions-and-scaling.md) requires.

**Scope:** `services/api` only. The parent app, child agents and the AI engine are not in these
stacks. They do include ElastiCache because the API fail-closes parent sessions when the cache is
unreachable (`services/api/src/lib/sessions.ts:139-145`).

`terraform apply` is **not** run by CI. CI (and agents) may run `fmt`, `validate` and `plan`;
creating or changing infrastructure is a human step.

## Two stacks, because `up`/`down` must be routine

Staging is applied before a release-signed run and destroyed after it. With one stack, `destroy`
would put the Secrets Manager entries into the deletion-recovery window (so the next `apply` fails
on the same names) and would throw away the validated ACM certificate (so it would need
re-validating every session). The split keeps the cheap, harmful-to-destroy resources out of the
teardown path.

| Stack | Lifetime | Contains |
|---|---|---|
| `base/` | created once, effectively never destroyed | ECR repository + lifecycle policy; the three Secrets Manager entries (and the `JWT_SECRET` / `VAULT_KEY` values); the ACM certificate and its Route 53 validation records; the ECS task execution role and its policies; the CloudWatch log group |
| `env/` | created and destroyed per session | VPC, subnets, IGW, NAT, route tables, security groups; ALB, listeners, target group; ECS cluster, service, task definition and autoscaling; RDS; ElastiCache; the per-session `DATABASE_URL` secret version |

`env/` reads `base/` through a `terraform_remote_state` data source (`env/remote_state.tf`), so
**base must be applied before env can even plan**. `env/` never creates a `base/` resource.

The S3 state bucket itself is created and hardened outside Terraform (versioned, SSE-S3, public
access blocked) and is not managed here.

## State

Both stacks use `osra-terraform-state-222207908538-me-central-1`, encrypted, versioned, with native
S3 locking (`use_lockfile = true`, Terraform >= 1.10). There is no DynamoDB table.

| Stack | Key |
|---|---|
| `base/` | `staging/base/terraform.tfstate` |
| `env/` | `staging/env/terraform.tfstate` |

Do not edit state by hand; use `terraform state ...`. `down.sh` only touches `env/`.

## Layout

| File | Contents |
|---|---|
| `up.sh` | base apply → env apply (no service) → migrate + seed → env apply (service) → prints the API URL, start time and cost |
| `down.sh` | env destroy only; prints elapsed time and estimated spend |
| `base/versions.tf` | Terraform/provider constraints and the base backend |
| `base/ecr.tf` | ECR repository and the 14-day untagged-image lifecycle policy |
| `base/secrets.tf` | Three secret containers; `JWT_SECRET` and `VAULT_KEY` values |
| `base/acm.tf` | Optional ACM certificate, DNS validation records and validation |
| `base/iam.tf` | ECS task execution role, managed attachment, read-the-secrets policy |
| `base/logs.tf` | CloudWatch log group `/ecs/osra-staging-api` |
| `base/outputs.tf` | ECR URL, secret ARNs, execution role, certificate ARN, log group |
| `env/versions.tf` | Terraform/provider constraints and the env backend |
| `env/remote_state.tf` | Reads `base/`'s outputs |
| `env/network.tf` | VPC, subnets, IGW, single NAT, route tables, security groups |
| `env/rds.tf` | PostgreSQL 16, `db.t4g.micro`, single-AZ by default, encrypted |
| `env/elasticache.tf` | One cache node (see *Cache engine* below) |
| `env/ecs.tf` | Cluster, task definition, ALB/listeners, service (gated for the seed), autoscaling |
| `env/secrets.tf` | Per-session `DATABASE_URL` version (RDS endpoint + password) |
| `env/outputs.tf` | ALB DNS, `api_url`, cluster/service, seed-task inputs, RDS/cache hosts |
| `*/terraform.tfvars.example` | Every value a human supplies |

## Prerequisites

- Terraform >= 1.10 (validated and planned with 1.16.6).
- AWS CLI v2 and any credential source for the staging account. **No profile name is committed**;
  the scripts default to `AWS_PROFILE=osra-staging` and `AWS_REGION=me-central-1` if unset.
- Docker with `buildx` and ARM64 emulation, or an ARM build runner, to publish the image.
- A Route 53 hosted zone only if base should create the certificate (release mode).

```bash
# Run from the repository root.
cp infra/terraform/base/terraform.tfvars.example infra/terraform/base/terraform.tfvars
cp infra/terraform/env/terraform.tfvars.example  infra/terraform/env/terraform.tfvars
export AWS_PROFILE=osra-staging
export AWS_REGION=me-central-1
```

Both `terraform.tfvars` files are gitignored. The examples use `<account-id>` placeholders, never
the real account.

## Everyday use: `up.sh` / `down.sh`

```bash
./infra/terraform/up.sh      # base (no-op) → env → migrate + seed → API service → URL, start time, cost
./infra/terraform/down.sh    # env only → elapsed time and estimated spend
```

`up.sh` is idempotent: base is applied first and changes nothing when it is already current. A fresh
session applies `env` **twice** — the first pass builds the network, database and cache but not the
ECS service, the seed runs against the migrated schema, then the second pass creates the service.
That order is not cosmetic: the API exits at boot when the Prisma client and the database disagree,
and Terraform waits for a new ECS service to become stable, so applying the service before the seed
would fail after ~20 minutes. On a re-run in the same session the service already exists and a
single apply is used.

Extra arguments (for example `-auto-approve`) are passed to the applies; a `-var-file` path would
have to be valid in both stacks, so prefer each stack's own `terraform.tfvars`.

Neither script ever runs `apply` or `destroy` against `base/` except `up.sh`'s base apply, which is
the one time base is meant to change. `down.sh` destroys `env/` and nothing else, and refuses to run
when `env/` has never been applied.

The scripts keep the session start in `infra/terraform/.session-start` (gitignored), so the spend
line in `down.sh` covers the whole session rather than only the destroy. Set
`HOURLY_COST_USD=<value>` to override the built-in estimate.

### First apply (ordering matters)

`env/api_image` has no default, and the repository is created by **base**. On a fresh account:

```bash
# 1. Base only: repository, secrets, IAM, log group, certificate.
terraform -chdir=infra/terraform/base apply

# 2. Build and push the ARM64 API image.
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REPO="$(terraform -chdir=infra/terraform/base output -raw ecr_repository_url)"
aws ecr get-login-password --region me-central-1 \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.me-central-1.amazonaws.com"
docker buildx build --platform linux/arm64 --tag "${REPO}:staging" --push services/api

# 3. Put "${REPO}:staging" into env/terraform.tfvars, then run the routine path.
./infra/terraform/up.sh
```

On later sessions only `up.sh` is needed: base already has the repository, secrets and certificate.

## Seed data is part of `up`, and mandatory

The database does not survive `down`, and the API exits at boot when its Prisma client and the
database schema disagree (`services/api/src/lib/schemaSync.ts:65-86`). So `up.sh` seeds after the
first env pass (which deliberately creates no ECS service — see *Everyday use* above):

```bash
aws ecs run-task --cluster "$cluster" --task-definition "$taskdef" --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$subnets],securityGroups=[$sg],assignPublicIp=DISABLED}" \
  --overrides '{"containerOverrides":[{"name":"api","command":["sh","-lc","pnpm exec prisma migrate deploy && pnpm exec tsx scripts/seed.ts"]}]}'
```

then waits for it to stop and fails `up.sh` if the container exits non-zero.

**Why a one-off ECS task and not a local command:** RDS has no public endpoint (`publicly_accessible
= false`, no `0.0.0.0/0` rule) and the private subnets reach the internet only through the NAT, so a
workstation cannot connect at all. Running the same task definition inside the VPC needs no local
Postgres, no VPN and no copy of the database password — `DATABASE_URL` arrives from Secrets Manager
exactly as it does for the API. The equivalent manual commands are
`pnpm --filter @familyshield/api db:migrate` and `pnpm --filter @familyshield/api db:seed`
(`services/api/package.json:10-13`, seed at `services/api/scripts/seed.ts`) — valid only from a host
that can already reach the private endpoint.

The seed is idempotent (`services/api/scripts/seed.ts` upserts the demo family), so a second `up.sh`
in the same session is harmless and re-runs it against the existing database.

The seed task uses the API image, so that image must carry `prisma`, `tsx` and `scripts/seed.ts`.
`services/api/Dockerfile` installs devDependencies (`--prod=false`) and copies the service, but both
its install and build end in `|| true` — a broken install still produces an image that only fails at
`CMD` (`docs/RELEASING.md` says the same). Check once per release:

```bash
docker run --rm --entrypoint sh <image> -c 'pnpm exec prisma --version && pnpm exec tsx --version'
```

## HTTPS: release mode vs non-release mode

`base/terraform.tfvars` controls it:

| Setting | Result |
|---|---|
| `domain_name = ""`, `certificate_arn = ""` | **Non-release mode.** No certificate exists, so `env` creates **no HTTPS listener** — there is no 443 target at all. The port-80 listener forwards to the API over plain HTTP, and `api_url` is `http://<alb-dns>.` |
| `domain_name` set, `hosted_zone_name` set | release mode: base creates an ACM certificate, publishes its DNS validation records in Route 53, waits for validation, and outputs the ARN |
| `certificate_arn` set | release mode with a certificate you issued elsewhere |

Whenever a certificate exists, the port-80 listener is a **301 redirect to HTTPS** and the 443
listener forwards to the target group. Non-release mode is stated plainly above because a release
build that refuses cleartext cannot be exercised against it.

## What each stack creates

`base`:

- ECR repository `osra-staging/api` with scan-on-push and a 14-day untagged-image lifecycle.
- Three Secrets Manager entries (`osra-staging/database-url`, `-jwt-secret`, `-vault-key`), with
  `JWT_SECRET` and `VAULT_KEY` values generated here and kept across sessions.
- Optional ACM certificate + Route 53 validation records (release mode).
- IAM task execution role: ECR pull, logs, and read those three secrets.
- CloudWatch log group `/ecs/osra-staging-api`, 14-day retention.

`env`:

- VPC `10.20.0.0/16`; two public subnets (ALB, NAT) and two private subnets (tasks, PostgreSQL,
  cache) across two AZs; internet gateway; **one** NAT gateway and EIP; route tables.
- Four security groups: ALB (80, and 443 only with a certificate), API (3000 from the ALB only),
  PostgreSQL (5432 from the API only), cache (6379 from the API only). The database has no
  `0.0.0.0/0` rule anywhere.
- RDS PostgreSQL 16, `db.t4g.micro`, 20 GB gp3, **single-AZ** by default, 1-day automated backups,
  encrypted, not publicly accessible, no final snapshot.
- ElastiCache, one `cache.t4g.micro` node, no snapshots.
- ECS cluster, ARM64 Fargate task (512 CPU / 1024 MiB), service with 2 tasks (created after the
  seed), autoscaling 2–4 on average CPU and ALB requests per target, circuit breaker with rollback.
- ALB, target group on `/health`, HTTP listener (plus HTTPS when base has a certificate, with the
  HTTP→HTTPS 301).
- The `DATABASE_URL` secret version for this session.

## Cache engine — Redis 7.1, not Valkey

`env/elasticache.tf` uses engine `redis`, version `7.1`, parameter family `redis7`.

On 2026-10-22 `aws elasticache describe-cache-engine-versions --region me-central-1 --engine valkey`
returned `InternalFailure` on three consecutive attempts, while `--engine redis` listed 6.2, 7.0 and
7.1. The API's ioredis client speaks the same protocol. **Production must recheck Valkey in
`me-central-1` before it matters** (ADR-0028 names Valkey).

## Cost

Rough **US$0.18/hour** for `env` at the defaults, on-demand list prices in `me-central-1` — about
**US$1.44 for an 8-hour session**. `base` is roughly **US$2/month** (ECR, three secrets, the log
group) and is always on. The certificate costs nothing while attached to the ALB. Excludes free-tier
credits, AWS Support, taxes and unpredictable data transfer. **This is an estimate, not a quote.**

| Item | Basis | US$/hour |
|---|---|---:|
| Fargate | 2 tasks × (0.5 vCPU + 1 GiB) | ~0.056 |
| RDS instance | `db.t4g.micro`, single-AZ | ~0.019 |
| RDS storage | 20 GB gp3, single-AZ | ~0.003 |
| NAT gateway | 1 gateway + light data processing | ~0.053 |
| Application load balancer | hourly + light LCU usage | ~0.030 |
| ElastiCache | 1 × `cache.t4g.micro` | ~0.018 |
| **Total (`env`)** | | **~0.18** |

Cost levers, in order of size: Multi-AZ RDS adds ~US$0.019/h and is off because a test run gains
nothing from a standby; a second NAT would add ~US$0.053/h; Fargate Spot would cut compute ~70% but
is not used for a service that should stay predictable.

## Destroy

`down.sh`, or by hand:

```bash
terraform -chdir=infra/terraform/env destroy
```

RDS deletion protection is **off**, no final snapshot is taken, and the database is lost — this is
what makes `up`/`down` routine. Base resources (ECR images, secrets, certificate, IAM, logs) stay.
`down.sh` prints the elapsed session time and the estimated spend, and refuses to run when `env` was
never applied.

Destroying `base` is a separate, deliberate act (`terraform -chdir=infra/terraform/base destroy`);
not needed for routine staging.

## Operational notes and deviations

- **Single NAT and a single cache node** trade availability for cost. ADR-0028's 99.9% target applies
  to production; a production per-region stack should use one NAT per AZ and a cache replica.
- **Multi-AZ is off** (`db_multi_az = false`). Production **must** set it true; ADR-0028 requires a
  standby. Staging turns it off because it is the slowest part of an apply and buys a test run
  nothing.
- **Database password:** `random_password` + our own `DATABASE_URL` secret is used instead of
  `manage_master_user_password`. Prisma needs one connection string, and composing it from an
  RDS-managed secret would read the password back into Terraform state anyway. It never appears in a
  committed file or the task definition, but it does live in state (as `random_password` and the
  secret version); the state bucket is encrypted and private for that reason.
- **A per-session password means a per-session `DATABASE_URL`.** That is why env owns the
  `DATABASE_URL` secret *version* while base owns the container: the value embeds the new RDS
  endpoint every time `up` runs.
- **Secrets encryption** uses the AWS-managed `aws/secretsmanager` key, not a customer-managed KMS
  key. A CMK is an easy later hardening step.
- **Email:** ADR-0028 mentions SES, but `services/api` sends through Resend
  (`services/api/src/lib/email/index.ts`). No SES resource is created; add `RESEND_API_KEY` as a
  secret when email is enabled. With no key, the API logs a warning and does not send.
- **Not included:** push credentials (`FCM_SERVICE_ACCOUNT_JSON`, APNs), `INTERNAL_HMAC_SECRET` for
  the AI engine, monitoring/alarms, a status page, and the AI engine itself.
- **Job schedulers** run in both API tasks. Digest rows and cache `SET NX` claims make that safe;
  leave `JOBS_ENABLED` unset unless an external scheduler owns the jobs.
- `CORS_ORIGIN` is unset by default, which makes the API reflect any origin. Set it via
  `cors_origin` once the parent web app has a stable origin.

## Checks

```bash
terraform -chdir=infra/terraform/base fmt -check -recursive
terraform -chdir=infra/terraform/base init && terraform -chdir=infra/terraform/base validate
terraform -chdir=infra/terraform/env  fmt -check -recursive
terraform -chdir=infra/terraform/env  init && terraform -chdir=infra/terraform/env  validate
terraform -chdir=infra/terraform/base plan
terraform -chdir=infra/terraform/env  plan   # needs base applied: env reads its outputs
```

`fmt` and `validate` need no credentials; both `init` calls and `plan` do. `env plan` fails with
`Unable to find remote state` until base has been applied at least once — that is the split working
as designed, not a fault in env.
