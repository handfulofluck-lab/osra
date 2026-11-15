# --- Audit and access logs (production, #766 item 2) ------------------------------------------
# VPC flow logs go to a bucket in this account; WAF logs and PostgreSQL logs go to CloudWatch. ALB access logs
# stay off: they store the full URL, and the WebSocket ticket is in the query string (see env/ecs.tf). Every one of them is kept exactly 90 days: at least 90 for an investigation (Ahmed), at most 90
# because the privacy policy promises it (site/privacy). Staging creates none of this (cost; nothing real
# flows there). The account-wide trail and GuardDuty are in org-audit/ and base/guardduty.tf.

locals {
  audit_logs_enabled = var.audit_logs_enabled
  audit_retention    = 90
}

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

# Flow logs delivered to S3 use SSE-S3 here (no extra key policy for log delivery).
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

# WAF requires the aws-waf-logs- prefix. Credentials, session cookies, the query string (the WebSocket ticket
# rides there) and the device signature header are redacted before they are stored.
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
  redacted_fields {
    single_header {
      name = "x-familyshield-signature"
    }
  }
  redacted_fields {
    query_string {}
  }
}

# Created before RDS exports to it, so it is kept 90 days instead of forever.
resource "aws_cloudwatch_log_group" "postgresql" {
  count = local.audit_logs_enabled ? 1 : 0

  name              = "/aws/rds/instance/${local.name_prefix}-postgres/postgresql"
  retention_in_days = local.audit_retention
}

data "aws_caller_identity" "current" {}
