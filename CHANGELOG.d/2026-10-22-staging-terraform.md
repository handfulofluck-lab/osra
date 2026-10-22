### Infra — staging on AWS me-central-1 is Terraform, split into base and env (#258, roadmap 5.8)
- The single stack is split in two so `up`/`down` can be routine: `base/` (ECR repository and lifecycle,
  the four Secrets Manager entries, the ACM certificate with its Route 53 validation records, the ECS
  task execution role, the CloudWatch log group) is applied once and effectively never destroyed, while
  `env/` (VPC/NAT/ALB/ECS/RDS/ElastiCache) is destroyed after each session. Destroying one stack used to
  park the secret names in the deletion-recovery window and force the certificate to be re-validated on
  every apply. Separate state keys: `staging/base/terraform.tfstate` and `staging/env/terraform.tfstate`;
  `env` reads base through `terraform_remote_state`.
- `infra/terraform/up.sh` and `down.sh` run the cycle: `up` applies base (idempotent), applies env, seeds,
  then prints the API URL, the start time and the hourly cost (~US$0.19/h; ~US$1.55 per 8-hour session,
  the public IPv4 addresses for the ALB and the NAT EIP included);
  `down` destroys env only and prints the session's elapsed time and estimated spend, refusing to run if
  env was never applied. Neither script destroys or rewrites base.
- A re-run of `up.sh` in the same session no longer applies everything before the seed: with the ECS
  service already in state it registers the new task definition alone
  (`apply -target=aws_ecs_task_definition.api`), migrates and seeds, then applies fully so the service
  rolls onto the tested image. Images are tagged by git sha, because a rebuild pushed to a moving
  `:staging` tag leaves the task definition unchanged and ECS keeps the old one. The service now sets
  `wait_for_steady_state = true`, so `up` fails instead of printing a URL for tasks that are
  crash-looping.
- Seeding is scripted into `up.sh` as a one-off `aws ecs run-task` on the API task definition with a
  command override (`prisma migrate deploy` then `scripts/seed.ts`): RDS is private, so the task runs
  inside the VPC, needs no local Postgres and no local copy of the database password. It is mandatory —
  the API exits at boot on schema drift, and the database does not survive `down`. A fresh `up` applies
  env twice (`api_service_enabled`): the service is created only after the seed, because Terraform waits
  for a new ECS service to stabilise and the API cannot stay up on an empty schema.
- The seed no longer contains a password that is published here: `resolveDemoPassword`
  (`services/api/scripts/seed-password.ts`, covered by `services/api/test/seed-demo-password.test.ts`)
  throws when `NODE_ENV=production` and `SEED_DEMO_PASSWORD` is unset, and the task definition injects
  that variable from a new `random_password` in base (`osra-staging/demo-password`, 24 alphanumeric
  characters, kept across sessions). Outside production the seed still falls back to the old default.
- Release mode now publishes the hostname: `base` outputs `domain_name` and `hosted_zone_id` (the zone
  is looked up whenever `hosted_zone_name` is set), `env/dns.tf` creates an A-record alias to the
  session's ALB, and `env` has no `domain_name` variable of its own, so the two stacks cannot disagree.
  Every `up` produced a new ALB DNS name, so before this the printed `api_url` resolved to nothing.
- Non-release mode can no longer serve the API in cleartext to the whole internet: the port-80 listener
  carries a precondition that refuses `allowed_cidrs = ["0.0.0.0/0"]` when base has no certificate.
  Narrow the range (your own address/32) or use release mode.
- RDS runs single-AZ by default (`db_multi_az = false`, with a comment that production must set it true),
  `backup_retention_period = 0` (the instance is destroyed every session), `skip_final_snapshot = true`,
  deletion protection off and encryption on. The apply is minutes shorter;
  a test run gains nothing from a standby.
- ElastiCache uses engine `redis` 7.1, not Valkey: `describe-cache-engine-versions --engine valkey` in
  `me-central-1` answered `InternalFailure` on three attempts while `--engine redis` listed 7.1.
  Production must recheck Valkey in the region before it matters.
- `.github/workflows/terraform.yml` runs what this README promised and nothing did: on a pull request
  touching `infra/terraform/**`, `terraform fmt -check -recursive` plus `init -backend=false` and
  `validate` in `base/` and `env/`, with Terraform 1.13.4 and no credentials. `terraform apply` remains a
  human step; `env`'s plan still needs `base` applied because it reads base's outputs, and that
  limitation is documented in `infra/terraform/README.md`.
