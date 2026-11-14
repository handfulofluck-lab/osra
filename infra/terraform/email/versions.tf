terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Same hardened state bucket as base, env and site, its own key. This stack is always on: up.sh and
  # down.sh never touch it, so the sending domain keeps its DKIM reputation between staging sessions.
  backend "s3" {
    bucket       = "osra-terraform-state-222207908538-eu-north-1"
    key          = "email/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}

# SES identities are per region. Staging runs in Stockholm (ADR-0030), so the API sends from there.
provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}
