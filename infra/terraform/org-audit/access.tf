# --- Access monitoring (#766 item 7) ---------------------------------------------------------------------
# Alarms on use of the deployer user (or a session it assumed) from an unexpected address, on changes to its
# keys, and on it creating new IAM principals; and an explicit deny that stops that user from switching any
# of this monitoring off. Rationale and owner decision: osra-security#27.

variable "agent_user_name" {
  description = "IAM user (management account) whose access key the agents use."
  type        = string
  default     = "osra-staging-deployer"
}

variable "agent_trusted_ip_prefixes" {
  description = "Expected source-address prefixes for the deployer user (tfvars only). Use from elsewhere alarms; nothing is blocked."
  type        = list(string)

  validation {
    condition     = length(var.agent_trusted_ip_prefixes) > 0 && alltrue([for p in var.agent_trusted_ip_prefixes : can(regex("^[0-9]{1,3}\\.([0-9]{1,3}\\.){0,2}$", p))])
    error_message = "Give at least one IPv4 prefix ending in a dot."
  }
}

variable "alarm_email" {
  description = "First address for access alarms (Karim's account email)."
  type        = string
}

variable "alarm_email_secondary" {
  description = "Second address for access alarms (support@)."
  type        = string

  validation {
    condition     = var.alarm_email_secondary != var.alarm_email
    error_message = "The second alarm address must differ from the first."
  }
}

variable "access_log_retention_days" {
  description = "Days the trail's CloudWatch copy is kept (the S3 copy follows trail_retention_days). Same 90 as every other server log."
  type        = number
  default     = 90
}

locals {
  agent_user_arn = "arn:aws:iam::${local.account_id}:user/${var.agent_user_name}"

  # Calls AWS services make on the caller's behalf carry a service name or "AWS Internal" as the source.
  agent_ip_clauses = join(" && ", concat(
    [for p in var.agent_trusted_ip_prefixes : "($.sourceIPAddress != \"${p}*\")"],
    ["($.sourceIPAddress != \"*.amazonaws.com\")", "($.sourceIPAddress != \"AWS Internal\")"],
  ))

  # The user itself, or a session assumed into a member account's OrganizationAccountAccessRole.
  agent_principal_clause = "(($.userIdentity.arn = \"${local.agent_user_arn}\") || ($.userIdentity.arn = \"*:assumed-role/OrganizationAccountAccessRole/*\"))"

  # New principals created by the deployer user itself: a way around the deny below, so it alarms. Expected
  # during an org-audit apply that adds a role; anything else is an incident.
  agent_new_principals = "($.userIdentity.arn = \"${local.agent_user_arn}\") && (($.eventName = \"CreateUser\") || ($.eventName = \"CreateRole\") || ($.eventName = \"CreateLoginProfile\") || ($.eventName = \"UpdateAssumeRolePolicy\") || ($.eventName = \"CreateOpenIDConnectProvider\") || ($.eventName = \"CreateSAMLProvider\") || ($.eventName = \"CreateAccountAssignment\") || ($.eventName = \"CreatePermissionSet\") || ($.eventName = \"CreateGroupMembership\") || (($.eventName = \"CreateAccessKey\") && ($.requestParameters.userName != \"${var.agent_user_name}\")))"

  agent_key_changes = "(($.eventName = \"CreateAccessKey\") || ($.eventName = \"UpdateAccessKey\") || ($.eventName = \"DeleteAccessKey\")) && ($.requestParameters.userName = \"${var.agent_user_name}\")"
}

# --- The trail's CloudWatch Logs copy -------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "trail" {
  name              = "/osra/org-trail"
  retention_in_days = var.access_log_retention_days
}

resource "aws_iam_role" "trail_to_logs" {
  name                 = "osra-org-trail-to-logs"
  permissions_boundary = aws_iam_policy.role_boundary.arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
    }]
  })
}

resource "aws_iam_role_policy" "trail_to_logs" {
  name = "write-org-trail-log-group"
  role = aws_iam_role.trail_to_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.trail.arn}:*"
    }]
  })
}

# --- Alarms ---------------------------------------------------------------------------------------------

resource "aws_kms_key" "access_alarms" {
  description         = "OSRA access alarms topic"
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
        # The AWS-managed aws/sns key cannot be used by CloudWatch, so an alarm on such a topic never arrives.
        Sid       = "CloudWatchPublishes"
        Effect    = "Allow"
        Principal = { Service = ["cloudwatch.amazonaws.com", "events.amazonaws.com"] }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
    ]
  })
}

resource "aws_sns_topic" "access_alarms" {
  name              = "osra-access-alarms"
  kms_master_key_id = aws_kms_key.access_alarms.arn
}

resource "aws_sns_topic_policy" "access_alarms" {
  arn = aws_sns_topic.access_alarms.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CloudWatchAlarmsAndGuardDuty"
      Effect    = "Allow"
      Principal = { Service = ["cloudwatch.amazonaws.com", "events.amazonaws.com"] }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.access_alarms.arn
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_sns_topic_subscription" "access_alarms" {
  for_each  = toset([var.alarm_email, var.alarm_email_secondary])
  topic_arn = aws_sns_topic.access_alarms.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_log_metric_filter" "agent_key_unexpected_source" {
  name           = "osra-agent-key-unexpected-source"
  log_group_name = aws_cloudwatch_log_group.trail.name
  pattern        = "{ ${local.agent_principal_clause} && ${local.agent_ip_clauses} }"

  metric_transformation {
    name          = "AgentKeyUnexpectedSource"
    namespace     = "OSRA/Access"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "agent_key_unexpected_source" {
  alarm_name          = "osra-agent-key-unexpected-source"
  alarm_description   = "The deployer user (or a session it assumed) was used from an unexpected address. Check /osra/org-trail; runbook: osra-security#27."
  namespace           = "OSRA/Access"
  metric_name         = "AgentKeyUnexpectedSource"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.access_alarms.arn]
}

resource "aws_cloudwatch_log_metric_filter" "agent_key_changed" {
  name           = "osra-agent-key-changed"
  log_group_name = aws_cloudwatch_log_group.trail.name
  pattern        = "{ ${local.agent_key_changes} }"

  metric_transformation {
    name          = "AgentKeyChanged"
    namespace     = "OSRA/Access"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "agent_key_changed" {
  alarm_name          = "osra-agent-key-changed"
  alarm_description   = "A key of the deployer user was created, disabled or deleted. Expected during rotate-agent-key.sh; anything else is an incident."
  namespace           = "OSRA/Access"
  metric_name         = "AgentKeyChanged"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.access_alarms.arn]
}

resource "aws_cloudwatch_log_metric_filter" "agent_new_principals" {
  name           = "osra-agent-new-principals"
  log_group_name = aws_cloudwatch_log_group.trail.name
  pattern        = "{ ${local.agent_new_principals} }"

  metric_transformation {
    name          = "AgentNewPrincipals"
    namespace     = "OSRA/Access"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "agent_new_principals" {
  alarm_name          = "osra-agent-new-principals"
  alarm_description   = "The deployer user created an IAM user, role, login profile or another user's key, or changed a role's trust. Expected only during an org-audit apply that adds a role."
  namespace           = "OSRA/Access"
  metric_name         = "AgentNewPrincipals"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.access_alarms.arn]
}

# --- The deployer user cannot switch its own watchers off (Karim, 14 Nov) ----------------------------------
# Nothing else is narrowed. Changing any of these resources later is done signed in through Identity Center
# with MFA; an apply of this stack by the deployer user that touches them fails by design.
locals {
  watched_alarm_arns = [
    aws_cloudwatch_metric_alarm.agent_key_unexpected_source.arn,
    aws_cloudwatch_metric_alarm.agent_key_changed.arn,
    aws_cloudwatch_metric_alarm.agent_new_principals.arn,
  ]
  watched_detector_arns = [
    aws_guardduty_detector.management.arn, "${aws_guardduty_detector.management.arn}/*",
    aws_guardduty_detector.management_us_east_1.arn, "${aws_guardduty_detector.management_us_east_1.arn}/*",
  ]
  watched_rule_arns = [
    aws_cloudwatch_event_rule.management_guardduty_high.arn,
    aws_cloudwatch_event_rule.management_guardduty_forward.arn,
    aws_cloudwatch_event_rule.access_key_too_old.arn,
  ]
}

# Three customer-managed policies, not one inline policy: an IAM user's inline policies are limited to 2,048
# characters in total, and a managed policy to 6,144. Split by purpose.
locals {
  agent_deny_policy_arns = [
    "arn:aws:iam::${local.account_id}:policy/osra-agent-keep-watchers",
    "arn:aws:iam::${local.account_id}:policy/osra-agent-no-escalation",
    "arn:aws:iam::${local.account_id}:policy/osra-agent-keep-backups-and-config",
    "arn:aws:iam::${local.account_id}:policy/osra-management-role-boundary",
  ]
}

resource "aws_iam_policy" "agent_keep_watchers" {
  name        = "osra-agent-keep-watchers"
  description = "The deployer user cannot switch off or erase the audit trail, its alarms or GuardDuty (Karim 14 Nov; Ahmed control 1)."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Trail"
        Effect   = "Deny"
        Action   = ["cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail", "cloudtrail:PutEventSelectors", "cloudtrail:PutInsightSelectors", "cloudtrail:RemoveTags"]
        Resource = aws_cloudtrail.org.arn
      },
      {
        Sid      = "TrailBucket"
        Effect   = "Deny"
        Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutLifecycleConfiguration", "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration", "s3:BypassGovernanceRetention", "s3:PutObjectRetention", "s3:PutObjectLegalHold", "s3:PutBucketObjectLockConfiguration"]
        Resource = [aws_s3_bucket.trail.arn, "${aws_s3_bucket.trail.arn}/*"]
      },
      {
        Sid      = "TrailLogGroupAndFilters"
        Effect   = "Deny"
        Action   = ["logs:DeleteLogGroup", "logs:DeleteMetricFilter", "logs:PutMetricFilter", "logs:PutRetentionPolicy", "logs:DeleteRetentionPolicy", "logs:DisassociateKmsKey", "logs:DeleteLogStream"]
        Resource = [aws_cloudwatch_log_group.trail.arn, "${aws_cloudwatch_log_group.trail.arn}:*"]
      },
      {
        Sid      = "Alarms"
        Effect   = "Deny"
        Action   = ["cloudwatch:DeleteAlarms", "cloudwatch:DisableAlarmActions", "cloudwatch:PutMetricAlarm", "cloudwatch:SetAlarmState"]
        Resource = local.watched_alarm_arns
      },
      {
        Sid      = "AlarmTopic"
        Effect   = "Deny"
        Action   = ["sns:DeleteTopic", "sns:SetTopicAttributes", "sns:AddPermission", "sns:RemovePermission", "sns:Unsubscribe", "sns:SetSubscriptionAttributes", "sns:PutDataProtectionPolicy"]
        Resource = [aws_sns_topic.access_alarms.arn, "${aws_sns_topic.access_alarms.arn}:*"]
      },
      {
        Sid      = "Keys"
        Effect   = "Deny"
        Action   = ["kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:PutKeyPolicy", "kms:DisableKeyRotation"]
        Resource = [aws_kms_key.trail.arn, aws_kms_key.access_alarms.arn, aws_kms_key.backup_copy.arn]
      },
      {
        Sid      = "GuardDuty"
        Effect   = "Deny"
        Action   = ["guardduty:DeleteDetector", "guardduty:UpdateDetector", "guardduty:CreateFilter", "guardduty:UpdateFilter", "guardduty:DeleteFilter", "guardduty:CreateIPSet", "guardduty:UpdateIPSet", "guardduty:ArchiveFindings", "guardduty:UpdateMalwareScanSettings"]
        Resource = local.watched_detector_arns
      },
      {
        Sid      = "GuardDutyAlertRules"
        Effect   = "Deny"
        Action   = ["events:DeleteRule", "events:DisableRule", "events:PutRule", "events:PutTargets", "events:RemoveTargets"]
        Resource = local.watched_rule_arns
      },
      {
        Sid      = "GuardDutyForwardRole"
        Effect   = "Deny"
        Action   = ["iam:DeleteRole", "iam:DeleteRolePolicy", "iam:PutRolePolicy", "iam:UpdateAssumeRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePermissionsBoundary"]
        Resource = aws_iam_role.guardduty_forward.arn
      },
      {
        Sid      = "TrailRole"
        Effect   = "Deny"
        Action   = ["iam:DeleteRole", "iam:DeleteRolePolicy", "iam:PutRolePolicy", "iam:UpdateAssumeRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePermissionsBoundary"]
        Resource = aws_iam_role.trail_to_logs.arn
      },
    ]
  })
}

resource "aws_iam_policy" "agent_keep_backups" {
  name        = "osra-agent-keep-backups-and-config"
  description = "The deployer user cannot erase the off-site backup copies or switch off AWS Config (Ahmed control 1)."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CopyVault"
        Effect   = "Deny"
        Action   = ["backup:DeleteBackupVaultLockConfiguration", "backup:PutBackupVaultAccessPolicy", "backup:DeleteBackupVaultAccessPolicy", "backup:DeleteBackupVault"]
        Resource = aws_backup_vault.production_copy.arn
      },
      {
        # Recovery points in the copy vault are RDS snapshots owned by this account.
        Sid      = "CopyRecoveryPoints"
        Effect   = "Deny"
        Action   = ["backup:DeleteRecoveryPoint", "backup:UpdateRecoveryPointLifecycle", "backup:DisassociateRecoveryPoint", "rds:DeleteDBSnapshot", "rds:DeleteDBClusterSnapshot"]
        Resource = "*"
      },
      {
        Sid      = "ConfigRecorder"
        Effect   = "Deny"
        Action   = ["config:StopConfigurationRecorder", "config:DeleteConfigurationRecorder", "config:PutConfigurationRecorder", "config:DeleteDeliveryChannel", "config:PutDeliveryChannel", "config:DeleteConfigRule", "config:PutConfigRule"]
        Resource = "*"
      },
      {
        Sid      = "ConfigBucket"
        Effect   = "Deny"
        Action   = ["s3:DeleteBucket", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutLifecycleConfiguration"]
        Resource = [aws_s3_bucket.config.arn, "${aws_s3_bucket.config.arn}/*"]
      },
      {
        Sid      = "ConfigRole"
        Effect   = "Deny"
        Action   = ["iam:DeleteRole", "iam:DeleteRolePolicy", "iam:PutRolePolicy", "iam:UpdateAssumeRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePermissionsBoundary"]
        Resource = aws_iam_role.config.arn
      },
    ]
  })
}

resource "aws_iam_policy" "agent_no_escalation" {
  name        = "osra-agent-no-escalation"
  description = "The deployer user cannot widen its own rights, act through new identities or roles here, or detach the organisation's controls (Ahmed control 2)."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The member-account half of the same rule (agent_guardrails.tf) stays attached and unchanged.
        Sid      = "KeepTheServiceControlPolicy"
        Effect   = "Deny"
        Action   = ["organizations:DetachPolicy", "organizations:DeletePolicy", "organizations:UpdatePolicy"]
        Resource = aws_organizations_policy.agent_cannot_erase_evidence.arn
      },
      {
        Sid      = "KeepServiceControlPoliciesOn"
        Effect   = "Deny"
        Action   = "organizations:DisablePolicyType"
        Resource = "*"
      },
      {
        # Fable's two remaining variants (osra-security#27 comment 6883240283): a role trusted by an outside
        # account, or handed to a service. Any role this user creates or gives a policy must carry the
        # boundary (role_boundary.tf); the boundary stays; roles go only to the services this stack uses.
        Sid       = "RolesCarryTheBoundary"
        Effect    = "Deny"
        Action    = ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:PutRolePermissionsBoundary"]
        Resource  = local.management_roles
        Condition = { StringNotEquals = { "iam:PermissionsBoundary" = local.boundary_arn } }
      },
      {
        # Fable seat 2, E5: a role trusted by an identity provider this user registered.
        Sid      = "NoOutsideIdentityProviders"
        Effect   = "Deny"
        Action   = ["iam:CreateOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint", "iam:AddClientIDToOpenIDConnectProvider", "iam:CreateSAMLProvider", "iam:UpdateSAMLProvider"]
        Resource = "*"
      },
      {
        # Fable seat 2, E6: Identity Center is Karim's way in; after the first apply only he changes it, with MFA.
        Sid      = "IdentityCenterStays"
        Effect   = "Deny"
        Action   = ["sso:CreateAccountAssignment", "sso:DeleteAccountAssignment", "sso:CreatePermissionSet", "sso:UpdatePermissionSet", "sso:AttachManagedPolicyToPermissionSet", "sso:PutInlinePolicyToPermissionSet", "sso:ProvisionPermissionSet", "identitystore:CreateUser", "identitystore:UpdateUser", "identitystore:CreateGroupMembership"]
        Resource = "*"
      },
      {
        Sid      = "BoundaryStays"
        Effect   = "Deny"
        Action   = "iam:DeleteRolePermissionsBoundary"
        Resource = "*"
      },
      {
        Sid       = "PassRoleOnlyToThisStacksServices"
        Effect    = "Deny"
        Action    = "iam:PassRole"
        Resource  = local.management_roles
        Condition = { StringNotEquals = { "iam:PassedToService" = ["cloudtrail.amazonaws.com", "events.amazonaws.com", "backup.amazonaws.com", "config.amazonaws.com"] } }
      },
      {
        Sid      = "DrillRoleTrust"
        Effect   = "Deny"
        Action   = ["iam:UpdateAssumeRolePolicy", "iam:DeleteRole"]
        Resource = aws_iam_role.restore_drill.arn
      },
      {
        # The indirect route (#784 review): a new role or user is not this user, so none of the denies above
        # would bind it, and it could remove the alarms before they fire. The agents reach production and
        # staging through roles in the member accounts and apply this stack as the user itself, so no
        # management-account role is needed.
        Sid      = "NoManagementRoles"
        Effect   = "Deny"
        Action   = "sts:AssumeRole"
        Resource = "arn:aws:iam::${local.account_id}:role/*"
      },
      {
        Sid      = "NoNewSignIns"
        Effect   = "Deny"
        Action   = ["iam:CreateUser", "iam:CreateLoginProfile", "iam:UpdateLoginProfile"]
        Resource = "*"
      },
      {
        Sid         = "NoKeysForOthers"
        Effect      = "Deny"
        Action      = ["iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:UpdateAccessKey"]
        NotResource = local.agent_user_arn
      },
      {
        Sid      = "OrganisationKeepsTheTrail"
        Effect   = "Deny"
        Action   = ["organizations:DisableAWSServiceAccess", "organizations:RemoveAccountFromOrganization", "organizations:DeregisterDelegatedAdministrator", "organizations:DeleteOrganization"]
        Resource = "*"
      },
      {
        # Including this policy itself.
        Sid      = "OwnPolicies"
        Effect   = "Deny"
        Action   = ["iam:PutUserPolicy", "iam:DeleteUserPolicy", "iam:AttachUserPolicy", "iam:DetachUserPolicy", "iam:PutUserPermissionsBoundary", "iam:DeleteUserPermissionsBoundary", "iam:AddUserToGroup", "iam:RemoveUserFromGroup"]
        Resource = local.agent_user_arn
      },
      {
        # Both deny policies stay as written: no new version, no deletion (detaching is OwnPolicies).
        Sid      = "OwnManagedPolicies"
        Effect   = "Deny"
        Action   = ["iam:CreatePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:DeletePolicyVersion", "iam:DeletePolicy", "iam:TagPolicy", "iam:UntagPolicy"]
        Resource = local.agent_deny_policy_arns
      },
    ]
  })
}

resource "aws_iam_user_policy_attachment" "agent_keep_watchers" {
  user       = var.agent_user_name
  policy_arn = aws_iam_policy.agent_keep_watchers.arn
}

resource "aws_iam_user_policy_attachment" "agent_keep_backups" {
  user       = var.agent_user_name
  policy_arn = aws_iam_policy.agent_keep_backups.arn
}

resource "aws_iam_user_policy_attachment" "agent_no_escalation" {
  user       = var.agent_user_name
  policy_arn = aws_iam_policy.agent_no_escalation.arn

  # Identity Center is set up by this same apply, before this policy takes it away (IdentityCenterStays).
  depends_on = [aws_ssoadmin_account_assignment.owner, aws_ssoadmin_managed_policy_attachment.admin]
}

output "access_alarms_topic_arn" {
  value = aws_sns_topic.access_alarms.arn
}
