terraform {
  # Native S3 state locking (`use_lockfile`) requires Terraform 1.10 or newer.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Staging's bucket is created and hardened outside Terraform (versioned, SSE-S3, public access
  # blocked); production's by the bootstrap-state stack. Each lives in its stack's region. Staging moved
  # to eu-north-1 on 2026-10-22 (ADR-0030); the abandoned me-central-1 bucket must never be named again.
  # Partial backend: bucket, key and region come from backend/<env>-base.hcl, passed by up.sh as
  # `terraform init -reconfigure -backend-config=...` (issue #714). One stack, two accounts: staging's
  # bucket is committed (backend/staging-base.hcl); production's is gitignored and built from its .example.
  # encrypt and use_lockfile are fixed here so neither environment can turn them off.
  backend "s3" {
    encrypt      = true
    use_lockfile = true # S3-native locking; no DynamoDB table to pay for or maintain
  }
}

provider "aws" {
  region = var.region

  # Production runs from the management-account deployer and assumes a role inside osra-production
  # (issue #714). Empty in staging, which runs in the account the profile already points at.
  dynamic "assume_role" {
    for_each = var.assume_role_arn != "" ? [var.assume_role_arn] : []
    content {
      role_arn     = assume_role.value
      session_name = "osra-terraform-${var.environment}"
    }
  }

  # A production tfvars file pins its account, so a staging profile (or a staging tfvars leaking into a
  # production run) fails at the first API call instead of planning against the wrong account.
  allowed_account_ids = length(var.allowed_account_ids) > 0 ? var.allowed_account_ids : null

  default_tags {
    tags = local.tags
  }
}
