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

  # Separate key from base: `down` destroys this stack and must leave base's state untouched.
  # Same bucket and region as base (both moved to eu-north-1 on 2026-10-22, ADR-0030).
  backend "s3" {
    bucket       = "osra-terraform-state-222207908538-eu-north-1"
    key          = "staging/env/terraform.tfstate"
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
