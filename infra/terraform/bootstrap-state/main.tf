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

variable "state_principal_arns" {
  description = "IAM principals (role ARNs) allowed to touch the state bucket at all (#766 item 1). Empty = only assume_role_arn. Everyone else, account administrators included, is denied by the bucket policy; the account root user can still repair the policy."
  type        = list(string)
  default     = []
}

locals {
  state_principals = distinct(concat([var.assume_role_arn], var.state_principal_arns))
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

# A customer-managed key (#766 item 1): reading state now needs kms:Decrypt on this key as well as
# s3:GetObject, and every use is a CloudTrail event. Objects written before this change stay AES256
# until their next write, which every apply does.
resource "aws_kms_key" "state" {
  description             = "OSRA production Terraform state"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/osra-terraform-state"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
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

# State may hold resource details worth protecting, so refuse any request not over TLS.
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

# Only the deploy role (and any principal named in state_principal_arns) may use the bucket at all.
data "aws_iam_policy_document" "state_principals" {
  source_policy_documents = [data.aws_iam_policy_document.state.json]

  statement {
    sid     = "DenyAllButStatePrincipals"
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
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = concat(local.state_principals, ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"])
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_principals.json

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

output "kms_key_arn" {
  description = "Key the state is encrypted with; set it as kms_key_id in backend/production-*.hcl."
  value       = aws_kms_key.state.arn
}
