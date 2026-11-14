# --- People: IAM Identity Center with MFA (#766 item 7) -------------------------------------------------
# The organisation's Identity Center instance already exists (us-east-1). This adds Karim as a user, an
# administrator permission set with an 8-hour session, and assigns it in the management account and in
# osra-production. Agents do not sign in here: they use the key in access.tf.
#
# Not in Terraform (no API): Settings → Authentication → "Require MFA: every time they sign in", and
# "If a user does not yet have a registered MFA device: require them to register one at sign-in". Set once
# in the console; README.md records the check. Karim registers his own device at first sign-in.

variable "identity_center_region" {
  description = "Region of the organisation's IAM Identity Center instance."
  type        = string
  default     = "us-east-1"
}

variable "owner_user_name" {
  description = "Identity Center user name for Karim."
  type        = string
}

variable "owner_given_name" {
  type = string
}

variable "owner_family_name" {
  type = string
}

variable "owner_email" {
  description = "Karim's sign-in email (tfvars only, never in the repository)."
  type        = string
}

provider "aws" {
  alias               = "sso"
  region              = var.identity_center_region
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      Project   = "osra"
      ManagedBy = "terraform"
      Purpose   = "org-audit"
    }
  }
}

data "aws_ssoadmin_instances" "this" {
  provider = aws.sso
}

locals {
  sso_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]
  owner_accounts = {
    management = var.management_account_id
    production = var.production_account_id
  }
}

resource "aws_identitystore_user" "owner" {
  provider          = aws.sso
  identity_store_id = local.identity_store_id

  user_name    = var.owner_user_name
  display_name = "${var.owner_given_name} ${var.owner_family_name}"

  name {
    given_name  = var.owner_given_name
    family_name = var.owner_family_name
  }

  emails {
    value   = var.owner_email
    primary = true
  }
}

resource "aws_ssoadmin_permission_set" "admin" {
  provider         = aws.sso
  instance_arn     = local.sso_instance_arn
  name             = "OsraAdministrator"
  description      = "Full administration for the owner; 8-hour sessions, MFA at every sign-in."
  session_duration = "PT8H"
}

resource "aws_ssoadmin_managed_policy_attachment" "admin" {
  provider           = aws.sso
  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_ssoadmin_account_assignment" "owner" {
  for_each = local.owner_accounts
  provider = aws.sso

  instance_arn       = local.sso_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.admin.arn
  principal_type     = "USER"
  principal_id       = aws_identitystore_user.owner.user_id
  target_type        = "AWS_ACCOUNT"
  target_id          = each.value

  depends_on = [aws_ssoadmin_managed_policy_attachment.admin]
}
