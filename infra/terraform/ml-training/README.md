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
| AWS Budget `osra-ml-training` | Alert at US$100 a month on the tag `Purpose=ml-training`, emailed to `budget_alert_emails` (at least one address is required). |

It creates no compute. Nothing here costs money while no job runs, apart from the KMS key
(about US$1 a month) and stored bytes.

## Who can reach the bucket

The bucket policy denies every principal except:

- the training role, and
- the roles listed in `operator_role_arns` (the deploy role, and the role that uploads files and
  starts jobs).

The training role can only read `input/`, write `output/` and `checkpoints/`, use the bucket key
(including a service-only grant for the encrypted training volume),
write logs under `/aws/sagemaker/TrainingJobs`, and pull images from the AWS Deep Learning
Containers registry. It has no access to RDS, Secrets Manager, or any other bucket. Its trust policy
allows `sagemaker.amazonaws.com` only, from this account only.

Karim's own Identity Center role is not in the allow list, on purpose: he cannot read or empty the
bucket himself. Add his role to `operator_role_arns` if he should.

Who read or wrote an object is not recorded: the organisation trail logs management events only. S3
data events for this one bucket would cost little and are worth adding before the bucket is used for
anything beyond the first run.

## Hard rule on content

`input/` holds only what the dataset list posted on the pull request allows: public research datasets
and made-up messages, each with its licence and whether it contains real persons' messages. Anything
that is real conversations of minors, or whose licence does not clearly allow this use, stays out
until Karim's lawyer has agreed. Nothing derived from an OSRA child's message ever goes in this bucket
(ADR-0033). Changing that needs a new design and a new review, not a new upload.

The job has no internet. See "Running a job".

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
terraform plan -lock-timeout=120s        # must refresh cleanly: proves operator_role_arns did not lock us out
```

If `init` is refused on the state key, or the apply is refused on a `kms:` action by the organisation
policy, stop and tell the owner of the production roots. Do not work around it.

## Running a job

Jobs are started with the CLI, not Terraform: a training job is a one-off, and it must always carry
a hard stop.

- `StoppingCondition.MaxRuntimeInSeconds` on every job. This is the real spending cap.
- Tag every job `Purpose=ml-training`.
- `OutputDataConfig.KmsKeyId` and `ResourceConfig.VolumeKmsKeyId` = the `kms_key_arn` output.
- `EnableNetworkIsolation=true`. The container cannot reach the internet, so it cannot send its input
  anywhere or fetch code nobody reviewed. The base model, tokenizer files and the training script are
  staged in `input/` first and given to the job as input channels. If a job ever needs a download, say
  which and why on a pull request first.
- KMS use stays on this one key: bucket, volume and output.
- One `ml.g5.xlarge` (or `ml.g4dn.xlarge`). A new account has a quota of 0 for both; the increase
  was requested on 15 Nov 2026.

## Budget tag

The budget filters on the cost allocation tag `Purpose`. Activate it once in the management account
(Billing, Cost allocation tags). Until then the budget exists but sees no spend.

## Removing it

Empty the bucket, then `terraform destroy`. The last step, scheduling the KMS key for deletion, is
refused for everyone but Karim by the organisation policy (batch F), so that step is his. The key is
deleted 30 days later.
