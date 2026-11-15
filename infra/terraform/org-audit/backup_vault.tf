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

# Binding retention (#783 review): with a lock, not even this account can delete a copy early or keep one
# past 90 days, whatever the vault policy says. GOVERNANCE mode (no changeable_for_days): a principal with
# backup:DeleteBackupVaultLockConfiguration can still remove it. COMPLIANCE mode would be permanent after its
# cooling-off period; that is Karim's decision to take, not a default (README).
resource "aws_backup_vault_lock_configuration" "production_copy" {
  provider = aws.copy

  backup_vault_name  = aws_backup_vault.production_copy.name
  min_retention_days = 1
  max_retention_days = 90
}

# --- Off-site restore drill (restore-drill.sh --from-copy) -------------------------------------------------
# An isolated network in the copy region: two private subnets, no internet gateway, a security group with no
# ingress. A drill instance restored here is reachable from nowhere and deleted by the script.
data "aws_availability_zones" "copy" {
  provider = aws.copy
  state    = "available"
}

resource "aws_vpc" "restore_drill" {
  provider = aws.copy

  cidr_block = "10.250.0.0/24"
  tags       = { Name = "osra-restore-drill" }
}

resource "aws_subnet" "restore_drill" {
  count    = 2
  provider = aws.copy

  vpc_id            = aws_vpc.restore_drill.id
  cidr_block        = cidrsubnet(aws_vpc.restore_drill.cidr_block, 1, count.index)
  availability_zone = data.aws_availability_zones.copy.names[count.index]
  tags              = { Name = "osra-restore-drill-${count.index}" }
}

resource "aws_db_subnet_group" "restore_drill" {
  provider = aws.copy

  name       = "osra-restore-drill"
  subnet_ids = aws_subnet.restore_drill[*].id
}

resource "aws_security_group" "restore_drill" {
  provider = aws.copy

  name        = "osra-restore-drill"
  description = "Restore drill instances: no ingress"
  vpc_id      = aws_vpc.restore_drill.id
}

resource "aws_iam_role" "restore_drill" {
  name                 = "osra-backup-restore-drill"
  permissions_boundary = aws_iam_policy.role_boundary.arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "restore_drill" {
  role       = aws_iam_role.restore_drill.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

output "management_account_id" {
  value = var.management_account_id
}

output "backup_copy_region" {
  value = var.backup_copy_region
}

output "backup_copy_vault_name" {
  value = aws_backup_vault.production_copy.name
}

output "restore_drill_subnet_group" {
  value = aws_db_subnet_group.restore_drill.name
}

output "restore_drill_security_group" {
  value = aws_security_group.restore_drill.id
}

output "restore_drill_role_arn" {
  value = aws_iam_role.restore_drill.arn
}

output "backup_copy_vault_arn" {
  description = "Set as backup_copy_vault_arn in env/production.tfvars."
  value       = aws_backup_vault.production_copy.arn
}
