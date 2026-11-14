terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Same hardened state bucket as base and env, its own key. This stack is always on: it is never
  # touched by up.sh or down.sh.
  backend "s3" {
    bucket       = "osra-terraform-state-222207908538-eu-north-1"
    key          = "site/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}

# The bucket lives with the rest of OSRA in Stockholm (ADR-0030 keeps staging there).
provider "aws" {
  region = "eu-north-1"

  default_tags {
    tags = local.tags
  }
}

# CloudFront only accepts certificates from us-east-1. The certificate is the only resource there.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = local.tags
  }
}
