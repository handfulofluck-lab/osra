# --- Organisation audit trail (#766 item 2) ---------------------------------------------------
# One CloudTrail trail for every account in the organisation, every region, management events, with log
# file validation. It lives in the MANAGEMENT account, so the record of what happened in osra-production
# is stored outside osra-production: production's own credentials cannot reach it. The management account's
# operators can, so the bucket also has S3 Object Lock (every log file kept unchangeable for the retention
# period) and the agents' key is denied every way of switching the trail, the lock or the bucket off
# (access.tf, #784). GOVERNANCE mode can still be bypassed by an identity granted s3:BypassGovernanceRetention;
# COMPLIANCE mode cannot be bypassed by anyone, root included, which is Karim's call (trail_lock_mode).
#
# Run from the management account (the deployer profile), never from a member account:
#   terraform -chdir=infra/terraform/org-audit init -backend-config=../backend/org-audit.hcl
#   terraform -chdir=infra/terraform/org-audit plan -var-file=org-audit.tfvars -out=org-audit.tfplan
# Prerequisites outside Terraform, once: CloudTrail's trusted access in Organizations
#   aws organizations enable-aws-service-access --service-principal cloudtrail.amazonaws.com
# (additive; it lets CloudTrail create the trail in member accounts and changes nothing else), and the two
# AWS Backup settings in backup_vault.tf.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

variable "region" {
  description = "Home region of the trail and its bucket."
  type        = string
  default     = "eu-central-1"
}

variable "management_account_id" {
  description = "The organisation's management account, so a member-account profile fails before it creates anything."
  type        = string
}

variable "trail_retention_days" {
  description = "Days the trail's log files are kept. Audit records about operators, not families; 365 is the usual minimum for an investigation."
  type        = number
  default     = 365
}

variable "trail_lock_mode" {
  description = "S3 Object Lock mode on the trail's log files. GOVERNANCE: bypassable only with s3:BypassGovernanceRetention. COMPLIANCE: no one can shorten or remove it (switching to it cannot be undone for files already written)."
  type        = string
  default     = "GOVERNANCE"

  validation {
    condition     = contains(["GOVERNANCE", "COMPLIANCE"], var.trail_lock_mode)
    error_message = "trail_lock_mode must be GOVERNANCE or COMPLIANCE."
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      Project   = "osra"
      ManagedBy = "terraform"
      Purpose   = "org-audit"
    }
  }
}

data "aws_organizations_organization" "this" {}
data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  org_id     = data.aws_organizations_organization.this.id
  trail_name = "osra-org-trail"
  trail_arn  = "arn:aws:cloudtrail:${var.region}:${local.account_id}:trail/${local.trail_name}"
}

resource "aws_kms_key" "trail" {
  description         = "OSRA organisation CloudTrail"
  enable_key_rotation = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdministers"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudTrailEncrypts"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "kms:GenerateDataKey*"
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:SourceArn" = local.trail_arn }
          StringLike   = { "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:aws:cloudtrail:*:${local.account_id}:trail/*" }
        }
      },
      {
        Sid       = "CloudTrailDescribes"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "kms:DescribeKey"
        Resource  = "*"
      },
    ]
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "trail" {
  name          = "alias/osra-org-trail"
  target_key_id = aws_kms_key.trail.key_id
}

resource "aws_s3_bucket" "trail" {
  bucket = "osra-org-trail-${local.account_id}-${var.region}"

  # Object Lock can only be switched on when the bucket is created; it also forces versioning on.
  object_lock_enabled = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Every log file is unchangeable and undeletable for as long as it is kept. The lifecycle rule's expiry then
# removes it on the same day the lock ends.
resource "aws_s3_bucket_object_lock_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    default_retention {
      mode = var.trail_lock_mode
      days = var.trail_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.trail]
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.trail.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.trail_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.trail.arn, "${aws_s3_bucket.trail.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "CloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.trail.arn
        Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
      },
      {
        Sid       = "CloudTrailWriteManagementAccount"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trail.arn}/AWSLogs/${local.account_id}/*"
        Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
      },
      {
        Sid       = "CloudTrailWriteOrganization"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trail.arn}/AWSLogs/${local.org_id}/*"
        Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.trail]
}

resource "aws_cloudtrail" "org" {
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.trail.id
  kms_key_id                    = aws_kms_key.trail.arn
  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true

  depends_on = [aws_s3_bucket_policy.trail, aws_s3_bucket_object_lock_configuration.trail]
}

output "trail_arn" {
  value = aws_cloudtrail.org.arn
}

output "trail_bucket" {
  value = aws_s3_bucket.trail.id
}
