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

  # The bucket is created and hardened outside this stack (versioned, SSE-S3, public access
  # blocked). It lives in the same region as the stack so state stays with the stack it belongs to.
  # Backend blocks cannot interpolate variables, so keep var.region in sync with this region.
  #
  # This region changed on 2026-10-22 (ADR-0030: staging moved to Stockholm because the UAE region
  # is damaged), so this names a new bucket. The old one,
  # osra-terraform-state-<account-id>-me-central-1, still exists and is left to be deleted together
  # with that base stack — pointing here at it again would read the abandoned stack's state.
  backend "s3" {
    bucket       = "osra-terraform-state-222207908538-eu-north-1"
    key          = "staging/base/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true # S3-native locking; no DynamoDB table to pay for or maintain
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}
