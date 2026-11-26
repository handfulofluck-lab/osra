# --- Backups outside the account and region (production, #766 item 5) ------------------------
# RDS keeps 14 days of point-in-time restore inside this account. That does not survive the account
# itself being lost or taken over, so AWS Backup also copies a daily backup to a vault in the MANAGEMENT
# account in another EU region (org-audit/backup_vault.tf). Both copies are deleted after 14 days, as the
# privacy notice promises (a deleted family's data leaves every backup within 14 days; threat model #892 §6).
#
# A cross-account copy of an RDS backup needs a customer-managed KMS key: a snapshot encrypted with the
# AWS-managed aws/rds key cannot be shared. Moving an existing instance to a new key means replacing it,
# which is why this is done now, while production's database is still empty.

locals {
  backup_enabled = var.backup_copy_vault_arn != ""
  # The privacy notice's promise. RDS point-in-time restore is 14 days as well (rds.tf).
  backup_retention_days = 14
}

resource "aws_kms_key" "rds" {
  count = var.db_customer_kms_key ? 1 : 0

  description         = "${local.name_prefix} PostgreSQL storage and backups"
  enable_key_rotation = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid       = "AccountAdministers"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      }],
      # The backup copy is re-encrypted in the destination vault; AWS Backup in the destination account
      # needs to read this key to do it. Only while the copy is on: with backup_offsite_copy_enabled = false
      # no other account can read the database key (#907 review).
      var.backup_copy_account_id != "" && var.backup_offsite_copy_enabled ? [{
        Sid       = "BackupCopyAccountReads"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.backup_copy_account_id}:root" }
        Action    = ["kms:Decrypt", "kms:DescribeKey", "kms:CreateGrant", "kms:ReEncrypt*", "kms:GenerateDataKey*"]
        Resource  = "*"
      }] : [],
    )
  })

  # No prevent_destroy (the mocked tests destroy what they create); a key deletion waits 30 days and can be
  # cancelled, and the database's deletion protection already stands in front of it.
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "rds" {
  count = var.db_customer_kms_key ? 1 : 0

  name          = "alias/${local.name_prefix}-rds"
  target_key_id = aws_kms_key.rds[0].key_id
}

resource "aws_backup_vault" "main" {
  count = local.backup_enabled ? 1 : 0

  name        = "${local.name_prefix}-vault"
  kms_key_arn = aws_kms_key.rds[0].arn
}

resource "aws_iam_role" "backup" {
  count = local.backup_enabled ? 1 : 0

  name = "${local.name_prefix}-backup"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  count = local.backup_enabled ? 1 : 0

  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  count = local.backup_enabled ? 1 : 0

  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_backup_plan" "main" {
  count = local.backup_enabled ? 1 : 0

  name = "${local.name_prefix}-daily"

  rule {
    rule_name         = "daily-with-offsite-copy"
    target_vault_name = aws_backup_vault.main[0].name
    # 01:00 UTC = 05:00 UAE, after the RDS backup window.
    schedule          = "cron(0 1 * * ? *)"
    start_window      = 60
    completion_window = 360

    lifecycle {
      delete_after = local.backup_retention_days
    }

    # The off-site copy (another account, another EU region). backup_offsite_copy_enabled = false keeps
    # the daily backup in this account and region only: the closed-beta option while the privacy notice
    # says backups stay in Frankfurt (#892 section 6). The rule name is kept so the switch is an in-place update.
    dynamic "copy_action" {
      for_each = var.backup_offsite_copy_enabled ? [1] : []
      content {
        destination_vault_arn = var.backup_copy_vault_arn
        lifecycle {
          delete_after = local.backup_retention_days
        }
      }
    }
  }
}

resource "aws_backup_selection" "rds" {
  count = local.backup_enabled ? 1 : 0

  name         = "${local.name_prefix}-rds"
  plan_id      = aws_backup_plan.main[0].id
  iam_role_arn = aws_iam_role.backup[0].arn
  resources    = [aws_db_instance.main.arn]
}
