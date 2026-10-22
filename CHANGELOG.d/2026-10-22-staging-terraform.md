### Infra — staging on AWS me-central-1 is Terraform, split into base and env (#258, roadmap 5.8)
- The single stack is split in two so `up`/`down` can be routine: `base/` (ECR repository and lifecycle,
  the three Secrets Manager entries, the ACM certificate with its Route 53 validation records, the ECS
  task execution role, the CloudWatch log group) is applied once and effectively never destroyed, while
  `env/` (VPC/NAT/ALB/ECS/RDS/ElastiCache) is destroyed after each session. Destroying one stack used to
  park the secret names in the deletion-recovery window and force the certificate to be re-validated on
  every apply. Separate state keys: `staging/base/terraform.tfstate` and `staging/env/terraform.tfstate`;
  `env` reads base through `terraform_remote_state`.
- `infra/terraform/up.sh` and `down.sh` run the cycle: `up` applies base (idempotent), applies env, seeds,
  then prints the API URL, the start time and the hourly cost (~US$0.18/h; ~US$1.44 per 8-hour session);
  `down` destroys env only and prints the session's elapsed time and estimated spend, refusing to run if
  env was never applied. Neither script destroys or rewrites base.
- Seeding is scripted into `up.sh` as a one-off `aws ecs run-task` on the API task definition with a
  command override (`prisma migrate deploy` then `scripts/seed.ts`): RDS is private, so the task runs
  inside the VPC, needs no local Postgres and no local copy of the database password. It is mandatory —
  the API exits at boot on schema drift, and the database does not survive `down`. A fresh `up` applies
  env twice (`api_service_enabled`): the service is created only after the seed, because Terraform waits
  for a new ECS service to stabilise and the API cannot stay up on an empty schema.
- RDS runs single-AZ by default (`db_multi_az = false`, with a comment that production must set it true),
  `skip_final_snapshot = true`, deletion protection off and encryption on. The apply is minutes shorter;
  a test run gains nothing from a standby.
- ElastiCache uses engine `redis` 7.1, not Valkey: `describe-cache-engine-versions --engine valkey` in
  `me-central-1` answered `InternalFailure` on three attempts while `--engine redis` listed 7.1.
  Production must recheck Valkey in the region before it matters.
- `terraform apply` remains a human step; CI and agents run only `fmt`, `validate` and `plan`. `env`'s
  plan needs `base` applied because it reads base's outputs, and that limitation is documented in
  `infra/terraform/README.md`.
