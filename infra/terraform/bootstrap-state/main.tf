# Production's Terraform state bucket (#714). Run once, before base, from the management-account
# deployer assuming the deploy role in osra-production. Its own state is LOCAL on purpose: the bucket
# cannot hold the state of the stack that creates it. Losing that local file loses nothing in AWS; the
# bucket can be taken back with `terraform import aws_s3_bucket.state <bucket>` and the three settings.
#
#   terraform -chdir=infra/terraform/bootstrap-state init
#   terraform -chdir=infra/terraform/bootstrap-state plan -var-file=production.tfvars
#   (apply only with Karim's written go — it creates a billed, if tiny, resource)

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  description = "Region of the stacks whose state this bucket holds."
  type        = string
  default     = "eu-central-1"
}

variable "assume_role_arn" {
  description = "Deploy role inside osra-production."
  type        = string
}

variable "allowed_account_ids" {
  description = "The production account ID, so a wrong profile fails before it creates anything."
  type        = list(string)

  validation {
    condition     = length(var.allowed_account_ids) == 1
    error_message = "Name exactly the one production account."
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = var.allowed_account_ids

  assume_role {
    role_arn     = var.assume_role_arn
    session_name = "osra-terraform-bootstrap-state"
  }

  default_tags {
    tags = {
      Project     = "osra"
      Environment = "production"
      ManagedBy   = "terraform"
      ADR         = "0028"
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  # Same naming as staging's hand-made bucket: osra-terraform-state-<account-id>-<region>.
  bucket = "osra-terraform-state-${data.aws_caller_identity.current.account_id}-${var.region}"

  # The state of every production stack lives here; a destroy would orphan all of it.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# State holds generated secrets (database password, JWT secret), so refuse any request not over TLS.
data "aws_iam_policy_document" "state" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.state.arn,
      "${aws_s3_bucket.state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# Old state versions are worth keeping for a while (a bad apply can be rolled back), not forever.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

output "state_bucket" {
  description = "Bucket name for backend/production-*.hcl and env's state_bucket."
  value       = aws_s3_bucket.state.bucket
}
