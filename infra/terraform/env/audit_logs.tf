# --- Audit and access logs (production, #766 item 2) ------------------------------------------
# ALB access logs and VPC flow logs go to one bucket in this account; WAF logs and PostgreSQL logs go to
# CloudWatch. Every one of them is kept exactly 90 days: at least 90 for an investigation (Ahmed), at most 90
# because the privacy policy promises it (site/privacy). Staging creates none of this (cost; nothing real
# flows there). The account-wide trail and GuardDuty are in org-audit/ and base/guardduty.tf.

locals {
  audit_logs_enabled = var.audit_logs_enabled
  audit_retention    = 90
}

data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket" "access_logs" {
  count = local.audit_logs_enabled ? 1 : 0

  bucket = "${local.name_prefix}-access-logs-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "${local.name_prefix}-access-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  count = local.audit_logs_enabled ? 1 : 0

  bucket                  = aws_s3_bucket.access_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  count = local.audit_logs_enabled ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ALB access logs accept only SSE-S3.
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  count = local.audit_logs_enabled ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  count = local.audit_logs_enabled ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id
  rule {
    id     = "expire-after-90-days"
    status = "Enabled"
    filter {}
    expiration {
      days = local.audit_retention
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  count = local.audit_logs_enabled ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.access_logs[0].arn, "${aws_s3_bucket.access_logs[0].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        # Regions older than August 2022 (eu-central-1 included) deliver ALB logs from the ELB account.
        Sid       = "AlbAccessLogs"
        Effect    = "Allow"
        Principal = { AWS = data.aws_elb_service_account.main.arn }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs[0].arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid       = "FlowLogsWrite"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.access_logs[0].arn}/vpc/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        Sid       = "FlowLogsAcl"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.access_logs[0].arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.access_logs]
}

resource "aws_flow_log" "vpc" {
  count = local.audit_logs_enabled ? 1 : 0

  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "s3"
  log_destination      = "${aws_s3_bucket.access_logs[0].arn}/vpc/"

  tags = {
    Name = "${local.name_prefix}-vpc-flow"
  }

  depends_on = [aws_s3_bucket_policy.access_logs]
}

# WAF requires the aws-waf-logs- prefix. Credentials and session cookies are redacted before they are stored.
resource "aws_cloudwatch_log_group" "waf" {
  count = local.audit_logs_enabled && var.waf_enabled ? 1 : 0

  name              = "aws-waf-logs-${local.name_prefix}-api"
  retention_in_days = local.audit_retention
}

resource "aws_wafv2_web_acl_logging_configuration" "api" {
  count = local.audit_logs_enabled && var.waf_enabled ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.api[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}

# Created before RDS exports to it, so it is kept 90 days instead of forever.
resource "aws_cloudwatch_log_group" "postgresql" {
  count = local.audit_logs_enabled ? 1 : 0

  name              = "/aws/rds/instance/${local.name_prefix}-postgres/postgresql"
  retention_in_days = local.audit_retention
}

data "aws_caller_identity" "current" {}
