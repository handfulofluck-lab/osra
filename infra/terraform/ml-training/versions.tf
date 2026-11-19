terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Its own root and its own state key, on purpose: the env stack's saved plans are what gets signed
  # for the API, and a training change must never appear in one of them (or the other way round).
  # Partial backend, like env: bucket, key, region, kms_key_id and assume_role come from
  # backend/production-ml-training.hcl (gitignored; copy the .example).
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  dynamic "assume_role" {
    for_each = var.assume_role_arn != "" ? [var.assume_role_arn] : []
    content {
      role_arn     = assume_role.value
      session_name = "osra-terraform-ml-training"
    }
  }

  # Pinned, so a wrong profile fails at the first API call instead of planning against another account.
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = local.tags
  }
}
