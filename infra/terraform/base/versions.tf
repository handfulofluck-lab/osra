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
  # blocked). It lives in the same region as the stack so state never leaves the UAE. Backend
  # blocks cannot interpolate variables, so keep var.region in sync with this region.
  backend "s3" {
    bucket       = "osra-terraform-state-222207908538-me-central-1"
    key          = "staging/base/terraform.tfstate"
    region       = "me-central-1"
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
