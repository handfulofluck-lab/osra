# --- The deployer user cannot erase evidence or backups, in any account (Ahmed, #637 comment 6881460052) ---
# Karim's decision (osra-security#27): the agents keep a permanent key with full rights. Ahmed's condition for
# signing against it: that key, and any role it assumes, cannot erase the evidence of what it did or the
# backups. In this account the user policy in access.tf does that; the agents reach osra-production through
# OrganizationAccountAccessRole, which an IAM user policy does not bind, so this service control policy does
# it there. It names only that role: Karim signs in through Identity Center (AWSReservedSSO_* roles) and is not
# affected, so anything below that is ever needed is done by him with MFA.
#
# Two things an IAM condition cannot express, and what covers them instead:
# - turning off RDS deletion protection (rds:ModifyDBInstance has no condition key for it): deleting the
#   instance, its snapshots, its automated backups and every recovery point is denied, so switching the
#   protection off gains nothing;
# - lowering the RDS backup retention: the AWS Backup recovery points, here and in the off-site copy vault
#   (management account, Vault Lock), are denied deletion.
# The restore drill's own throw-away instance (*-restore-drill-*) is the one deletion left open.

locals {
  agent_role_pattern = "arn:aws:iam::*:role/OrganizationAccountAccessRole"
}

resource "aws_organizations_policy" "agent_cannot_erase_evidence" {
  name        = "osra-agent-cannot-erase-evidence"
  description = "OrganizationAccountAccessRole (the agents' route into member accounts) cannot erase audit evidence or backups."
  type        = "SERVICE_CONTROL_POLICY"
  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AuditServices"
        Effect = "Deny"
        Action = [
          "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail", "cloudtrail:PutEventSelectors",
          "guardduty:DeleteDetector", "guardduty:UpdateDetector", "guardduty:CreateFilter", "guardduty:UpdateFilter",
          "guardduty:DeleteFilter", "guardduty:ArchiveFindings", "guardduty:CreateIPSet", "guardduty:UpdateIPSet",
          "guardduty:DisassociateFromAdministratorAccount",
          "config:StopConfigurationRecorder", "config:DeleteConfigurationRecorder", "config:DeleteDeliveryChannel",
          "config:DeleteConfigRule",
        ]
        Resource  = "*"
        Condition = { ArnLike = { "aws:PrincipalArn" = local.agent_role_pattern } }
      },
      {
        Sid    = "AuditLogs"
        Effect = "Deny"
        Action = ["logs:DeleteLogGroup", "logs:DeleteLogStream", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy", "logs:DisassociateKmsKey"]
        Resource = [
          "arn:aws:logs:*:*:log-group:aws-waf-logs-*",
          "arn:aws:logs:*:*:log-group:/aws/rds/*",
        ]
        Condition = { ArnLike = { "aws:PrincipalArn" = local.agent_role_pattern } }
      },
      {
        Sid    = "AccessLogBucket"
        Effect = "Deny"
        Action = ["s3:DeleteBucket", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutLifecycleConfiguration", "s3:PutBucketVersioning"]
        Resource = [
          "arn:aws:s3:::*-access-logs-*",
          "arn:aws:s3:::*-access-logs-*/*",
        ]
        Condition = { ArnLike = { "aws:PrincipalArn" = local.agent_role_pattern } }
      },
      {
        Sid       = "AlarmsAndTopic"
        Effect    = "Deny"
        Action    = ["cloudwatch:DeleteAlarms", "cloudwatch:DisableAlarmActions", "sns:DeleteTopic", "sns:SetTopicAttributes", "sns:Unsubscribe", "sns:RemovePermission"]
        Resource  = ["arn:aws:cloudwatch:*:*:alarm:osra-*", "arn:aws:sns:*:*:osra-*-alarms", "arn:aws:sns:*:*:osra-*-alarms:*"]
        Condition = { ArnLike = { "aws:PrincipalArn" = local.agent_role_pattern } }
      },
      {
        Sid       = "Keys"
        Effect    = "Deny"
        Action    = ["kms:ScheduleKeyDeletion", "kms:DisableKey"]
        Resource  = "*"
        Condition = { ArnLike = { "aws:PrincipalArn" = local.agent_role_pattern } }
      },
      {
        Sid    = "Backups"
        Effect = "Deny"
        Action = [
          "rds:DeleteDBSnapshot", "rds:DeleteDBClusterSnapshot", "rds:DeleteDBInstanceAutomatedBackup", "rds:DeleteDBCluster",
          "backup:DeleteRecoveryPoint", "backup:UpdateRecoveryPointLifecycle", "backup:DisassociateRecoveryPoint",
          "backup:DeleteBackupVault", "backup:DeleteBackupVaultLockConfiguration", "backup:PutBackupVaultAccessPolicy",
          "backup:DeleteBackupVaultAccessPolicy", "backup:DeleteBackupPlan", "backup:DeleteBackupSelection",
        ]
        Resource  = "*"
        Condition = { ArnLike = { "aws:PrincipalArn" = local.agent_role_pattern } }
      },
      {
        Sid         = "DatabaseInstances"
        Effect      = "Deny"
        Action      = "rds:DeleteDBInstance"
        NotResource = "arn:aws:rds:*:*:db:*-restore-drill-*"
        Condition   = { ArnLike = { "aws:PrincipalArn" = local.agent_role_pattern } }
      },
    ]
  })
}

resource "aws_organizations_policy_attachment" "agent_cannot_erase_evidence_production" {
  policy_id = aws_organizations_policy.agent_cannot_erase_evidence.id
  target_id = var.production_account_id
}

# --- Key age (Ahmed's control 3) -------------------------------------------------------------------------
# AWS Config records IAM users in this account only; the managed rule ACCESS_KEYS_ROTATED marks any key older
# than 100 days non-compliant, and that change is mailed through the access alarm topic. Claude rotates the
# key monthly (rotate-agent-key.sh, osra-security#27), so the alarm means a rotation was missed.

resource "aws_s3_bucket" "config" {
  bucket = "osra-config-${local.account_id}-${var.region}"
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.trail_retention_days
    }
  }
}

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.config.arn, "${aws_s3_bucket.config.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "ConfigAclCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.config.arn
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
      {
        Sid       = "ConfigWrite"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config.arn}/AWSLogs/${local.account_id}/Config/*"
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id, "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.config]
}

resource "aws_iam_role" "config" {
  name                 = "osra-config-recorder"
  permissions_boundary = aws_iam_policy.role_boundary.arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "management" {
  name     = "osra-management"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = false
    include_global_resource_types = false
    resource_types                = ["AWS::IAM::User"]
  }
}

resource "aws_config_delivery_channel" "management" {
  name           = "osra-management"
  s3_bucket_name = aws_s3_bucket.config.id

  depends_on = [aws_config_configuration_recorder.management, aws_s3_bucket_policy.config]
}

resource "aws_config_configuration_recorder_status" "management" {
  name       = aws_config_configuration_recorder.management.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.management]
}

resource "aws_config_config_rule" "access_keys_rotated" {
  name = "osra-access-keys-rotated"

  source {
    owner             = "AWS"
    source_identifier = "ACCESS_KEYS_ROTATED"
  }

  input_parameters            = jsonencode({ maxAccessKeyAge = "100" })
  maximum_execution_frequency = "TwentyFour_Hours"

  depends_on = [aws_config_configuration_recorder_status.management]
}

resource "aws_cloudwatch_event_rule" "access_key_too_old" {
  name        = "osra-access-key-too-old"
  description = "An access key in the management account is older than 100 days"
  event_pattern = jsonencode({
    source        = ["aws.config"]
    "detail-type" = ["Config Rules Compliance Change"]
    detail = {
      configRuleName      = [aws_config_config_rule.access_keys_rotated.name]
      newEvaluationResult = { complianceType = ["NON_COMPLIANT"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "access_key_too_old" {
  rule = aws_cloudwatch_event_rule.access_key_too_old.name
  arn  = aws_sns_topic.access_alarms.arn
}

output "agent_scp_id" {
  value = aws_organizations_policy.agent_cannot_erase_evidence.id
}
