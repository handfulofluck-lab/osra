# --- Roles in the management account carry a boundary (Fable, osra-security#27 comment 6883240283) -------
# The deployer user's denies bind only that user. A role it creates or changes could otherwise act for it:
# trusted by an outside account, or handed to a service. So every role this user creates, or gives a policy
# to, must carry this boundary, which repeats the watcher denies; the boundary itself cannot be changed or
# removed, and roles can be passed only to the four services this stack uses. Karim's Identity Center roles
# are created by Identity Center, not by this user, and are not affected.
#
# The boundary names actions on "*" (not ARNs) so it fits in one managed policy; no role this stack makes
# needs any of them.

resource "aws_iam_policy" "role_boundary" {
  name        = "osra-management-role-boundary"
  description = "Boundary for every role the deployer user creates in the management account: anything except the watcher denies."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Everything"
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      },
      {
        Sid    = "NotTheWatchers"
        Effect = "Deny"
        Action = [
          "cloudtrail:StopLogging", "cloudtrail:DeleteTrail", "cloudtrail:UpdateTrail", "cloudtrail:PutEventSelectors",
          "guardduty:DeleteDetector", "guardduty:UpdateDetector", "guardduty:CreateFilter", "guardduty:UpdateFilter",
          "guardduty:DeleteFilter", "guardduty:ArchiveFindings",
          "config:StopConfigurationRecorder", "config:DeleteConfigurationRecorder", "config:PutConfigurationRecorder",
          "config:DeleteDeliveryChannel", "config:DeleteConfigRule",
          "s3:BypassGovernanceRetention", "s3:PutBucketObjectLockConfiguration", "s3:PutObjectRetention", "s3:PutObjectLegalHold",
          "backup:DeleteRecoveryPoint", "backup:UpdateRecoveryPointLifecycle", "backup:DisassociateRecoveryPoint",
          "backup:DeleteBackupVault", "backup:DeleteBackupVaultLockConfiguration", "backup:PutBackupVaultAccessPolicy",
          "rds:DeleteDBSnapshot", "rds:DeleteDBClusterSnapshot",
          "kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:PutKeyPolicy",
          "cloudwatch:DeleteAlarms", "cloudwatch:DisableAlarmActions",
          "sns:DeleteTopic", "sns:Unsubscribe",
          "events:DeleteRule", "events:DisableRule", "events:RemoveTargets",
          "iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile", "iam:UpdateLoginProfile",
          "iam:PutUserPolicy", "iam:AttachUserPolicy", "iam:DeleteUserPolicy", "iam:DetachUserPolicy",
          "iam:DeleteRolePermissionsBoundary", "iam:DeleteUserPermissionsBoundary",
          "iam:CreatePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:DeletePolicy",
          "organizations:DetachPolicy", "organizations:DeletePolicy", "organizations:UpdatePolicy",
          "organizations:DisablePolicyType", "organizations:DisableAWSServiceAccess",
          "organizations:RemoveAccountFromOrganization", "organizations:DeleteOrganization",
        ]
        Resource = "*"
      },
      {
        # A role under this boundary cannot make an unbounded role, or reach Identity Center or an outside
        # identity provider, either: the same rules as the deployer user (access.tf).
        Sid       = "NoUnboundedRoles"
        Effect    = "Deny"
        Action    = ["iam:CreateRole", "iam:PutRolePolicy", "iam:AttachRolePolicy", "iam:PutRolePermissionsBoundary"]
        Resource  = "*"
        Condition = { StringNotEquals = { "iam:PermissionsBoundary" = local.boundary_arn } }
      },
      {
        Sid       = "PassRoleOnlyToThisStacksServices"
        Effect    = "Deny"
        Action    = "iam:PassRole"
        Resource  = "*"
        Condition = { StringNotEquals = { "iam:PassedToService" = ["cloudtrail.amazonaws.com", "events.amazonaws.com", "backup.amazonaws.com", "config.amazonaws.com"] } }
      },
      {
        Sid      = "NoNewWaysIn"
        Effect   = "Deny"
        Action   = ["iam:CreateOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint", "iam:AddClientIDToOpenIDConnectProvider", "iam:CreateSAMLProvider", "iam:UpdateSAMLProvider", "sso:*", "sso-directory:*", "identitystore:Add*", "identitystore:Create*", "identitystore:Delete*", "identitystore:Remove*", "identitystore:Update*", "organizations:RegisterDelegatedAdministrator", "organizations:CreateAccount", "organizations:InviteAccountToOrganization"]
        Resource = "*"
      },
      {
        Sid      = "NotTheAuditStores"
        Effect   = "Deny"
        Action   = ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:DeleteBucket", "s3:PutBucketPolicy", "s3:PutLifecycleConfiguration", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:DeleteMetricFilter"]
        Resource = [aws_s3_bucket.trail.arn, "${aws_s3_bucket.trail.arn}/*", aws_s3_bucket.config.arn, "${aws_s3_bucket.config.arn}/*", aws_cloudwatch_log_group.trail.arn, "${aws_cloudwatch_log_group.trail.arn}:*"]
      },
    ]
  })
}

locals {
  management_roles = "arn:aws:iam::${local.account_id}:role/*"
  boundary_arn     = "arn:aws:iam::${local.account_id}:policy/osra-management-role-boundary"
}
