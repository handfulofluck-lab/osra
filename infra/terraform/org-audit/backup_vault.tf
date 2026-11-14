# --- Off-site backup copy (#766 item 5) -------------------------------------------------------
# osra-production copies its daily database backup here: another account (this one, the management
# account) and another EU region. Losing or compromising the production account leaves this copy intact.
# Copies expire after 90 days (set by the production plan's copy rule; the privacy policy promises it).
#
# Prerequisites outside Terraform, once, in this account:
#   aws organizations enable-aws-service-access --service-principal backup.amazonaws.com
#   aws backup update-global-settings --global-settings isCrossAccountBackupEnabled=true

variable "backup_copy_region" {
  description = "EU region for the copy; must differ from production's (eu-central-1)."
  type        = string
  default     = "eu-west-1"
}

variable "production_account_id" {
  description = "osra-production, the only account allowed to copy into the vault."
  type        = string
}

provider "aws" {
  alias               = "copy"
  region              = var.backup_copy_region
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      Project   = "osra"
      ManagedBy = "terraform"
      Purpose   = "backup-copy"
    }
  }
}

resource "aws_kms_key" "backup_copy" {
  provider = aws.copy

  description         = "OSRA production backup copies"
  enable_key_rotation = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "backup_copy" {
  provider = aws.copy

  name          = "alias/osra-production-backup-copy"
  target_key_id = aws_kms_key.backup_copy.key_id
}

resource "aws_backup_vault" "production_copy" {
  provider = aws.copy

  name        = "osra-production-copy"
  kms_key_arn = aws_kms_key.backup_copy.arn
}

resource "aws_backup_vault_policy" "production_copy" {
  provider = aws.copy

  backup_vault_name = aws_backup_vault.production_copy.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ProductionMayCopyIn"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.production_account_id}:root" }
        Action    = "backup:CopyIntoBackupVault"
        Resource  = "*"
      },
      {
        # Nobody deletes a copy early, the production account included; expiry does it.
        Sid       = "NoEarlyDelete"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["backup:DeleteRecoveryPoint", "backup:UpdateRecoveryPointLifecycle"]
        Resource  = "*"
      },
    ]
  })
}

output "backup_copy_vault_arn" {
  description = "Set as backup_copy_vault_arn in env/production.tfvars."
  value       = aws_backup_vault.production_copy.arn
}
