# ml-training: storage and role for training OSRA's own model

A separate Terraform root with its own state key (`production/ml-training/terraform.tfstate`). It is
not part of `env`, so a training change never appears in a signed API plan, and an API change never
appears here. `up.sh` and `down.sh` do not touch it.

Decided by Karim on 15 Nov 2026 (thread "Integration with OCL and building our own AI model"):
rent a GPU for training, and copy the training text to a private bucket in Frankfurt. Training data
is public research datasets and made-up messages only. No real child data is ever put here
(ADR-0033).

## What it creates (osra-production, eu-central-1)

| Resource | Purpose |
|---|---|
| S3 bucket `osra-ml-training-<account>-eu-central-1` | `input/` training text, `output/` model files, `checkpoints/`. Private, KMS-encrypted, no versioning, everything expires after `expire_after_days` (30). |
| KMS key `alias/osra-ml-training` | Encrypts the bucket, the job volume and the job output. |
| IAM role `osra-ml-training` | What a SageMaker training job runs as. |
| AWS Budget `osra-ml-training` | Alert at US$100 a month on the tag `Purpose=ml-training`. |

It creates no compute. Nothing here costs money while no job runs, apart from the KMS key
(about US$1 a month) and stored bytes.

## Who can reach the bucket

The bucket policy denies every principal except:

- the training role, and
- the roles listed in `operator_role_arns` (the deploy role, and the role that uploads files and
  starts jobs).

The training role can only read `input/`, write `output/` and `checkpoints/`, use the bucket key,
write logs under `/aws/sagemaker/TrainingJobs`, and pull images from the AWS Deep Learning
Containers registry. It has no access to RDS, Secrets Manager, or any other bucket. Its trust policy
allows `sagemaker.amazonaws.com` only, from this account only.

## Apply

Production applies follow the usual rule: reviewed plan (Fable R3 plus Kimi or K31), then Karim's
written go.

```sh
cd infra/terraform/ml-training
cp ../backend/production-ml-training.hcl.example ../backend/production-ml-training.hcl   # fill in
cp terraform.tfvars.example terraform.tfvars                                             # fill in
terraform init -reconfigure -backend-config=../backend/production-ml-training.hcl
terraform plan -lock-timeout=120s -out=ml-training.tfplan
terraform apply ml-training.tfplan
```

## Running a job

Jobs are started with the CLI, not Terraform: a training job is a one-off, and it must always carry
a hard stop.

- `StoppingCondition.MaxRuntimeInSeconds` on every job. This is the real spending cap.
- Tag every job `Purpose=ml-training`.
- `OutputDataConfig.KmsKeyId` and `ResourceConfig.VolumeKmsKeyId` = the `kms_key_arn` output.
- One `ml.g5.xlarge` (or `ml.g4dn.xlarge`). A new account has a quota of 0 for both; the increase
  was requested on 15 Nov 2026.

## Budget tag

The budget filters on the cost allocation tag `Purpose`. Activate it once in the management account
(Billing, Cost allocation tags). Until then the budget exists but sees no spend.

## Removing it

Empty the bucket, then `terraform destroy`. The KMS key is deleted 30 days later.
