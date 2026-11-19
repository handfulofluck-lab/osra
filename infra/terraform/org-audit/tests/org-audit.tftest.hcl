# Plan-only checks with mock providers: no AWS credentials, nothing is created.

mock_provider "archive" {
  override_during = plan

  mock_data "archive_file" {
    defaults = {
      output_base64sha256 = "YCoQYoqgQx8Qtwqjigrx6rXERFW47VGZ81PODdD2UWQ="
      output_path         = "fixture-expiry.zip"
    }
  }
}

mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }
  mock_data "aws_organizations_organization" {
    defaults = {
      id = "o-test"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:eu-central-1:000000000000:key/test"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::000000000000:policy/test"
    }
  }
  mock_resource "aws_organizations_policy" {
    defaults = {
      arn = "arn:aws:organizations::000000000000:policy/o-test/service_control_policy/p-test1234"
      id  = "p-test1234"
    }
  }
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:eu-central-1:000000000000:test"
    }
  }
  mock_resource "aws_cloudwatch_metric_alarm" {
    defaults = {
      arn = "arn:aws:cloudwatch:eu-central-1:000000000000:alarm:test"
    }
  }
  mock_resource "aws_cloudtrail" {
    defaults = {
      arn = "arn:aws:cloudtrail:eu-central-1:000000000000:trail/test"
    }
  }
  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::test"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:eu-central-1:000000000000:log-group:test"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::000000000000:role/test"
    }
  }
  mock_resource "aws_guardduty_detector" {
    defaults = {
      arn = "arn:aws:guardduty:eu-central-1:000000000000:detector/test"
    }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:eu-central-1:000000000000:rule/test"
    }
  }
}

mock_provider "aws" {
  override_during = plan

  alias = "us_east_1"

  mock_resource "aws_guardduty_detector" {
    defaults = {
      arn = "arn:aws:guardduty:us-east-1:000000000000:detector/test"
    }
  }
  mock_resource "aws_cloudwatch_event_rule" {
    defaults = {
      arn = "arn:aws:events:us-east-1:000000000000:rule/test"
    }
  }
}

mock_provider "aws" {
  override_during = plan

  alias = "sso"

  mock_data "aws_ssoadmin_instances" {
    defaults = {
      arns               = ["arn:aws:sso:::instance/ssoins-test"]
      identity_store_ids = ["d-test"]
    }
  }
  mock_resource "aws_identitystore_user" {
    defaults = {
      user_id = "00000000-0000-0000-0000-000000000000"
    }
  }
  mock_resource "aws_ssoadmin_permission_set" {
    defaults = {
      arn = "arn:aws:sso:::permissionSet/ssoins-test/ps-test"
    }
  }
}

mock_provider "aws" {
  override_during = plan

  alias = "copy"

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
    }
  }
  mock_resource "aws_backup_vault" {
    defaults = {
      arn = "arn:aws:backup:eu-west-1:000000000000:backup-vault:osra-production-copy"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:eu-west-1:000000000000:key/copy"
    }
  }
}

variables {
  management_account_id = format("%012d", 0)
  production_account_id = join("", [for _ in range(12) : "1"])
  agent_user_names      = ["osra-staging-deployer", "osra-codex-mac"]
  agent_trusted_ip_prefixes = {
    osra-staging-deployer = [format("%d.%d.%d.", 192, 0, 2)]
    osra-codex-mac        = [format("%d.%d.%d.", 198, 51, 100)]
  }
  mac_phase1_regions          = ["eu-central-1"]
  mac_phase1_entry_role_names = { review-entry = "fixture-phase1-reader" }
  mac_access_expires_at       = "2000-01-15T00:00:00Z"
  alarm_email                 = "a@example.com"
  alarm_email_secondary       = "b@example.com"
  owner_user_name             = "owner"
  owner_given_name            = "Test"
  owner_family_name           = "Owner"
  owner_email                 = "owner@example.com"
}

run "trail_bucket_is_object_locked" {
  command = plan

  assert {
    condition     = aws_s3_bucket.trail.object_lock_enabled
    error_message = "the trail bucket must be created with S3 Object Lock (#782)"
  }
  assert {
    condition     = one(aws_s3_bucket_object_lock_configuration.trail.rule).default_retention[0].mode == "GOVERNANCE" && one(aws_s3_bucket_object_lock_configuration.trail.rule).default_retention[0].days == 365
    error_message = "trail log files are locked in GOVERNANCE mode for the full 365-day retention by default"
  }
}

run "compliance_mode_is_an_option" {
  command = plan

  variables {
    trail_lock_mode = "COMPLIANCE"
  }

  assert {
    condition     = one(aws_s3_bucket_object_lock_configuration.trail.rule).default_retention[0].mode == "COMPLIANCE"
    error_message = "trail_lock_mode = COMPLIANCE must reach the lock rule"
  }
}

run "lock_mode_is_validated" {
  command = plan

  variables {
    trail_lock_mode = "OFF"
  }

  expect_failures = [var.trail_lock_mode]
}

run "management_account_has_guardduty" {
  command = plan

  assert {
    condition     = aws_guardduty_detector.management.enable && aws_guardduty_detector.management_us_east_1.enable
    error_message = "the management account needs GuardDuty in the home region and us-east-1 (#782)"
  }
}

run "backup_copy_vault_is_locked" {
  command = plan

  assert {
    condition     = aws_backup_vault_lock_configuration.production_copy.min_retention_days >= 1 && aws_db_subnet_group.restore_drill.name == "osra-restore-drill"
    error_message = "the cross-account backup copy vault must have Vault Lock, and the restore drill its own subnet group (#783)"
  }
}

run "agent_key_cannot_switch_off_lock_or_guardduty" {
  command = plan

  assert {
    condition     = alltrue([for a in ["s3:BypassGovernanceRetention", "s3:PutObjectRetention", "s3:PutObjectLegalHold", "s3:PutBucketObjectLockConfiguration", "guardduty:DeleteDetector", "guardduty:CreateFilter", "events:DisableRule", "sts:AssumeRole", "iam:CreateUser", "iam:CreateLoginProfile", "iam:UpdateLoginProfile", "iam:CreateAccessKey", "NotResource", "organizations:DisableAWSServiceAccess", "organizations:RemoveAccountFromOrganization", "organizations:DeregisterDelegatedAdministrator", "organizations:DeleteOrganization", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePermissionsBoundary", "backup:DeleteBackupVaultLockConfiguration", "backup:PutBackupVaultAccessPolicy", "backup:DeleteBackupVaultAccessPolicy", "backup:DeleteBackupVault", "backup:DeleteRecoveryPoint", "rds:DeleteDBSnapshot", "config:StopConfigurationRecorder", "organizations:DetachPolicy", "organizations:DisablePolicyType", "iam:DeleteAccessKey", "iam:CreatePolicyVersion"] : strcontains("${aws_iam_policy.agent_keep_watchers.policy}${aws_iam_policy.agent_no_escalation.policy}${aws_iam_policy.agent_keep_backups.policy}", a)])
    error_message = "the deployer user must be denied bypassing the Object Lock, switching off management GuardDuty or its alert rules, the copy vault, and the indirect route through new roles, users, keys or the organisation (#782, #784)"
  }
  assert {
    condition     = aws_cloudwatch_event_target.management_guardduty_forward.arn == "arn:aws:events:eu-central-1:000000000000:event-bus/default"
    error_message = "us-east-1 GuardDuty findings must be forwarded to the home region's bus"
  }
}

run "ahmed_controls_fit_and_reach_production" {
  command = plan

  assert {
    # Managed policies are capped at 6,144 characters; leave room for real ARNs, longer than the mocks.
    condition     = alltrue([for p in [aws_iam_policy.agent_keep_watchers.policy, aws_iam_policy.agent_no_escalation.policy, aws_iam_policy.agent_keep_backups.policy, aws_iam_policy.role_boundary.policy] : length(p) < 4500])
    error_message = "each deny policy must stay well under the 6,144-character managed-policy limit (real ARNs add ~700 characters to the mocks)"
  }
  assert {
    condition     = length(aws_organizations_policy.agent_cannot_erase_evidence.content) < 5120 && aws_organizations_policy_attachment.agent_cannot_erase_evidence_production.target_id == "111111111111"
    error_message = "the evidence SCP must fit the 5,120-character limit and be attached to osra-production"
  }
  assert {
    condition     = alltrue([for a in ["rds:DeleteDBSnapshot", "backup:DeleteRecoveryPoint", "guardduty:DeleteDetector", "cloudtrail:StopLogging", "config:StopConfigurationRecorder", "cloudwatch:DeleteAlarms", "cloudwatch:SetAlarmState", "kms:ScheduleKeyDeletion", "-restore-drill-"] : strcontains(aws_organizations_policy.agent_cannot_erase_evidence.content, a)])
    error_message = "the SCP must cover audit services, logs, alarms, keys and backups, leaving only the drill instance deletable"
  }
  assert {
    # Keep the eight original deny conditions exact; the ninth, Mac-only deadline has a distinct
    # condition. Pin cardinality and the full SID set rather than exempting an unbounded set of rows.
    condition = (length(jsondecode(aws_organizations_policy.agent_cannot_erase_evidence.content).Statement) == 9 &&
      toset([for st in jsondecode(aws_organizations_policy.agent_cannot_erase_evidence.content).Statement : st.Sid]) == toset([
        "AuditServices", "AuditLogs", "AccessLogBucket", "AlarmsAndTopic", "Keys", "Backups", "DatabaseInstances", "ReservedAndBackupRolesStay", "MacAuthorizationExpired",
      ]) && alltrue([for st in jsondecode(aws_organizations_policy.agent_cannot_erase_evidence.content).Statement : st.Effect == "Deny"]) &&
      alltrue([for st in jsondecode(aws_organizations_policy.agent_cannot_erase_evidence.content).Statement :
        jsonencode(st.Condition) == jsonencode(st.Sid == "Backups" ? local.not_karim_or_backup : local.not_karim)
        if st.Sid != "MacAuthorizationExpired"
        ]) && jsonencode(one([for st in jsondecode(aws_organizations_policy.agent_cannot_erase_evidence.content).Statement : st if st.Sid == "MacAuthorizationExpired"]).Condition) == jsonencode({
        DateGreaterThanEquals = { "aws:CurrentTime" = var.mac_access_expires_at }
        StringEquals          = { "aws:SourceIdentity" = "osra-codex-mac" }
      })
    )
    error_message = "the SCP must retain exactly eight original deny conditions plus the exact Mac-only literal-deadline condition"
  }
  assert {
    condition = anytrue([for st in jsondecode(aws_organizations_policy.agent_cannot_erase_evidence.content).Statement :
      st.Sid == "ReservedAndBackupRolesStay" && contains(st.Action, "iam:CreateRole") && contains(st.Action, "iam:UpdateAssumeRolePolicy")
      && jsonencode(st.Resource) == jsonencode(["arn:aws:iam::*:role/aws-reserved/*", "arn:aws:iam::111111111111:role/osra-production-backup"])
    ])
    error_message = "no one but Karim may create or re-trust a role under aws-reserved/ or change AWS Backup's role"
  }
  assert {
    condition     = jsondecode(aws_config_config_rule.access_keys_rotated.input_parameters).maxAccessKeyAge == "100" && aws_cloudwatch_event_target.access_key_too_old.arn == aws_sns_topic.access_alarms.arn
    error_message = "a key older than 100 days must be mailed through the access alarm topic"
  }
}

run "roles_carry_the_boundary" {
  command = plan

  assert {
    condition     = alltrue([for r in [aws_iam_role.trail_to_logs, aws_iam_role.config, aws_iam_role.restore_drill, aws_iam_role.guardduty_forward] : r.permissions_boundary == aws_iam_policy.role_boundary.arn])
    error_message = "every role this stack makes in the management account must carry the boundary"
  }
  assert {
    condition     = alltrue([for a in ["iam:PermissionsBoundary", "iam:PassedToService", "iam:DeleteRolePermissionsBoundary", "osra-management-role-boundary", "iam:CreateOpenIDConnectProvider", "iam:CreateSAMLProvider", "sso-directory:*", "sso:Create*", "sso:Delete*", "sso:Put*", "sso:Update*", "identitystore:Delete*", "identitystore:Update*", "organizations:RegisterDelegatedAdministrator"] : strcontains(aws_iam_policy.agent_no_escalation.policy, a)])
    error_message = "the deployer user must be held to the boundary when it creates or changes roles, pass roles only to this stack's services, and register no identity provider or Identity Center access (Fable E4-E6)"
  }
  assert {
    condition     = alltrue([for a in ["cloudtrail:StopLogging", "s3:BypassGovernanceRetention", "backup:DeleteRecoveryPoint", "iam:CreateAccessKey", "organizations:DetachPolicy", "sso-directory:*", "identitystore:Delete*", "organizations:RegisterDelegatedAdministrator"] : strcontains(aws_iam_policy.role_boundary.policy, a)])
    error_message = "the boundary must repeat the watcher denies"
  }
}

run "both_agents_have_isolated_watchers_and_protected_policy_surfaces" {
  command = plan

  assert {
    condition = (alltrue([for user in var.agent_user_names :
      aws_iam_user_policy_attachment.agent_keep_watchers[user].user == user &&
      aws_iam_user_policy_attachment.agent_keep_backups[user].user == user &&
      aws_iam_user_policy_attachment.agent_no_escalation[user].user == user
      ]) && aws_iam_user.codex_mac.permissions_boundary == aws_iam_policy.role_boundary.arn
    )
    error_message = "both agents need the three direct denies; Mac also needs the reviewed permissions boundary"
  }
  assert {
    condition = (alltrue([for user in var.agent_user_names :
      strcontains(aws_cloudwatch_log_metric_filter.agent_key_unexpected_source_by_user[user].pattern, local.agent_user_arns[user]) &&
      strcontains(aws_cloudwatch_log_metric_filter.agent_key_unexpected_source_by_user[user].pattern, "userIdentity.sessionContext.sourceIdentity") &&
      strcontains(aws_cloudwatch_log_metric_filter.agent_key_unexpected_source_by_user[user].pattern, "\"${user}\"") &&
      strcontains(aws_cloudwatch_log_metric_filter.agent_key_unexpected_source_by_user[user].pattern, "${var.agent_trusted_ip_prefixes[user][0]}*") &&
      aws_cloudwatch_metric_alarm.agent_key_unexpected_source_by_user[user].metric_name == "AgentKeyUnexpectedSource-${user}" &&
      strcontains(aws_cloudwatch_log_metric_filter.agent_key_changed[user].pattern, "$.requestParameters.userName = \"${user}\"") &&
      strcontains(aws_cloudwatch_log_metric_filter.agent_new_principals[user].pattern, "userIdentity.sessionContext.sourceIdentity")
      ])
    )
    error_message = "each agent needs three isolated filters/alarms and its own trusted prefixes; role attribution uses SourceIdentity"
  }
  assert {
    condition = (strcontains(aws_cloudwatch_log_metric_filter.agent_key_unexpected_source.pattern, "*:assumed-role/OrganizationAccountAccessRole/*") &&
      aws_cloudwatch_metric_alarm.agent_key_unexpected_source.alarm_name == "osra-agent-key-unexpected-source" &&
      aws_cloudwatch_metric_alarm.agent_key_changed["osra-staging-deployer"].alarm_name == "osra-agent-key-changed" &&
      aws_cloudwatch_metric_alarm.agent_new_principals["osra-staging-deployer"].alarm_name == "osra-agent-new-principals"
    )
    error_message = "keep the legacy umbrella and existing PC alarm identities until private CloudTrail migration evidence exists"
  }
  assert {
    condition = (one([for statement in jsondecode(aws_iam_policy.agent_no_escalation.policy).Statement : statement if statement.Sid == "NoKeysForOthers"]).NotResource == local.agent_own_key_arn &&
      toset(one([for statement in jsondecode(aws_iam_policy.agent_no_escalation.policy).Statement : statement if statement.Sid == "OwnPolicies"]).Resource) == toset(values(local.agent_user_arns)) &&
      toset(one([for statement in jsondecode(aws_iam_policy.agent_no_escalation.policy).Statement : statement if statement.Sid == "AccessDeadlineStays"]).Resource) == toset(values(local.agent_user_arns))
    )
    error_message = "keys must exempt only the caller, while policy/boundary and deadline-tag protections cover both users"
  }
  assert {
    condition = (alltrue([for filter in aws_cloudwatch_log_metric_filter.agent_new_principals : length(filter.pattern) <= 1024])
    )
    error_message = "per-user principal filters must fit CloudWatch Logs' 1024-character filter-pattern limit"
  }
}

run "self_key_exception_is_account_bound_and_roles_fail_closed" {
  command = plan

  # Mutants: a shared two-user NotResource would permit cross-agent keys; removing the principal-type
  # or PC-only username guard would leave absent username context to IAM variable evaluation instead of a deny.
  assert {
    condition = (alltrue([for user in var.agent_user_names :
      replace(one([for statement in jsondecode(aws_iam_policy.role_boundary.policy).Statement : statement if statement.Sid == "KeysOnlyForOwnUser"]).NotResource, "$${aws:username}", user) == local.agent_user_arns[user]
      ]) && !strcontains(local.agent_own_key_arn, "::*:") &&
      local.agent_user_arns["osra-staging-deployer"] != local.agent_user_arns["osra-codex-mac"]
    )
    error_message = "additional PC key guards must bind the account and caller; unconditional creation denial remains"
  }
  assert {
    condition = (toset(one([for statement in jsondecode(aws_iam_policy.role_boundary.policy).Statement : statement if statement.Sid == "KeysOnlyForOwnUser"]).Action) == toset(["iam:CreateAccessKey", "iam:DeleteAccessKey", "iam:UpdateAccessKey", "iam:ListAccessKeys"]) &&
      one([for statement in jsondecode(aws_iam_policy.role_boundary.policy).Statement : statement if statement.Sid == "NoRoleKeyManagement"]).Condition.StringNotEquals["aws:PrincipalType"] == "User" &&
      one([for statement in jsondecode(aws_iam_policy.role_boundary.policy).Statement : statement if statement.Sid == "NoKeysWithoutUsername"]).Condition.StringNotEquals["aws:username"] == "osra-staging-deployer"
    )
    error_message = "additional PC-only guards must deny Mac, roles and missing username; the separate creation deny is unconditional"
  }
  assert {
    condition = (contains(one([for statement in jsondecode(aws_iam_policy.role_boundary.policy).Statement : statement if statement.Sid == "NotTheWatchers"]).Action, "iam:CreateAccessKey") &&
      alltrue([for statement in jsondecode(aws_iam_policy.role_boundary.policy).Statement : statement.Effect == "Deny" if statement.Sid != "Everything"])
    )
    error_message = "the baseline unconditional CreateAccessKey deny must remain; no own-user creation exception is introduced"
  }
}

run "agent_entry_trust_requires_immutable_source_identity" {
  command = plan

  assert {
    condition = (local.production_entry_agent_trust_statements[0].Effect == "Deny" &&
      local.production_entry_agent_trust_statements[0].Condition.StringNotEquals["sts:SourceIdentity"] == "$${aws:username}" &&
      local.production_entry_agent_trust_statements[1].Effect == "Allow" &&
      local.production_entry_agent_trust_statements[1].Condition.StringEquals["sts:SourceIdentity"] == "$${aws:username}" &&
      alltrue([for statement in local.production_entry_agent_trust_statements : toset(statement.Action) == toset(["sts:AssumeRole", "sts:SetSourceIdentity"]) && toset(statement.Principal.AWS) == toset([local.agent_user_arns["osra-codex-mac"]])])
    )
    error_message = "Mac-only trust additions need the explicit user ARN, matching SourceIdentity, SetSourceIdentity, and a deny that cannot be bypassed by old root trust"
  }
  assert {
    condition = (aws_iam_user.codex_mac.tags["osra:access-expires-at"] == var.mac_access_expires_at &&
      one([for statement in jsondecode(aws_iam_policy.agent_no_escalation.policy).Statement : statement if statement.Sid == "AccessDeadlineStays"]).Condition["ForAnyValue:StringEqualsIgnoreCase"]["aws:TagKeys"] == ["osra:access-expires-at"]
    )
    error_message = "the fixed owner-set deadline must be tagged and protected from either agent; rotation is not renewal"
  }
}

run "mac_authorization_expiry_is_narrow_and_protected" {
  command = plan

  assert {
    condition = (toset(local.mac_expiry_execution_statements[0].Action) == toset(["iam:ListUserTags", "iam:ListAccessKeys", "iam:UpdateAccessKey"]) &&
      local.mac_expiry_execution_statements[0].Resource == local.agent_user_arns["osra-codex-mac"] &&
      aws_iam_role.mac_expiry.permissions_boundary == aws_iam_policy.mac_expiry_boundary.arn &&
      aws_iam_role_policy.mac_expiry.policy == aws_iam_policy.mac_expiry_boundary.policy
    )
    error_message = "the expiry role and its separate narrow boundary permit only Mac metadata/status and its own logs"
  }
  assert {
    condition = (alltrue([for policy in [aws_iam_policy.agent_keep_backups.policy, aws_iam_policy.role_boundary.policy] :
      toset(one([for statement in jsondecode(policy).Statement : statement if statement.Sid == "ExpiryStays"]).Resource) == toset(local.mac_expiry_resource_arns) &&
      one([for statement in jsondecode(policy).Statement : statement if statement.Sid == "ExpiryStays"]).Effect == "Deny"
      ]) && aws_cloudwatch_event_rule.mac_expiry.schedule_expression == "rate(1 minute)" &&
      aws_cloudwatch_event_rule.mac_expiry.state == "ENABLED"
    )
    error_message = "both agent users and roles under the original boundary must be unable to alter the expiry guard"
  }
  assert {
    condition = (aws_lambda_permission.mac_expiry.source_arn == aws_cloudwatch_event_rule.mac_expiry.arn &&
      aws_lambda_permission.mac_expiry.source_account == local.account_id &&
      aws_lambda_permission.mac_expiry.principal == "events.amazonaws.com" &&
      aws_cloudwatch_metric_alarm.mac_expiry_health["missing"].treat_missing_data == "breaching"
    )
    error_message = "invoke only from the exact same-account rule, and alarm if scheduled invocation disappears"
  }
}

run "mac_literal_deadline_guards_are_partial_and_deny_only" {
  command = plan

  assert {
    condition = (aws_iam_user_policy.mac_authorization_deadline.user == aws_iam_user.codex_mac.name &&
      one(jsondecode(aws_iam_user_policy.mac_authorization_deadline.policy).Statement).Condition.DateGreaterThanEquals["aws:CurrentTime"] == var.mac_access_expires_at &&
      one(jsondecode(aws_iam_user_policy.mac_authorization_deadline.policy).Statement).Effect == "Deny" &&
      length(aws_iam_user_policy.mac_authorization_deadline.policy) < 2048
    )
    error_message = "the existing Mac user needs a deny-only literal deadline within the inline-policy limit"
  }
  assert {
    condition = (one([for statement in jsondecode(aws_organizations_policy.agent_cannot_erase_evidence.content).Statement : statement if statement.Sid == "MacAuthorizationExpired"]).Condition.DateGreaterThanEquals["aws:CurrentTime"] == var.mac_access_expires_at &&
      one([for statement in jsondecode(aws_organizations_policy.agent_cannot_erase_evidence.content).Statement : statement if statement.Sid == "MacAuthorizationExpired"]).Condition.StringEquals["aws:SourceIdentity"] == "osra-codex-mac" &&
      aws_organizations_policy_attachment.agent_cannot_erase_evidence_production.target_id == var.production_account_id
    )
    error_message = "only the existing production attachment is covered, and its new deadline deny requires the exact Mac SourceIdentity"
  }
}

run "mac_phase1_is_explicit_metadata_with_independent_ceilings" {
  command = plan

  # Mutants: an administrator attachment, wildcard read grant, missing Mac ceiling,
  # unrelated production target, or permissive source-identity entry must fail.
  assert {
    condition = (length(local.mac_phase1_metadata_actions) == 49 &&
      alltrue([for action in local.mac_phase1_metadata_actions : !strcontains(action, "*")]) &&
      aws_iam_user_policy_attachment.mac_phase1_readonly.policy_arn == aws_iam_policy.mac_phase1_readonly.arn &&
      aws_iam_user_policy_attachment.mac_phase1_ceiling.policy_arn == aws_iam_policy.mac_phase1_ceiling.arn &&
      length(aws_iam_policy.mac_phase1_readonly.policy) < 4500 &&
      length(aws_iam_policy.mac_phase1_ceiling.policy) < 4500 &&
      length(aws_organizations_policy.mac_phase1_ceiling.content) < 5120
    )
    error_message = "Mac phase1 must have explicit metadata actions and both independently budgeted ceilings"
  }
  assert {
    condition = (alltrue([for action in ["iam:*", "organizations:*", "secretsmanager:GetSecretValue", "ssm:*", "kms:Decrypt", "rds-data:*", "rds-db:connect", "s3:GetObject*", "logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan", "ecs:ExecuteCommand", "cloudtrail:LookupEvents"] : contains(local.mac_phase1_data_denies, action)]) &&
      aws_organizations_policy_attachment.mac_phase1_ceiling_production.target_id == var.production_account_id &&
      length(jsondecode(aws_organizations_policy.mac_phase1_ceiling.content).Statement) == 5 &&
      alltrue([for statement in jsondecode(aws_organizations_policy.mac_phase1_ceiling.content).Statement : statement.Condition.StringEquals["aws:SourceIdentity"] == "osra-codex-mac"])
    )
    error_message = "the explicit content deny must also constrain Mac-attributed sessions on the existing production target"
  }
  assert {
    condition = (one([for statement in jsondecode(aws_iam_policy.mac_phase1_ceiling.policy).Statement : statement if statement.Sid == "RequireMacSourceIdentity"]).Condition.StringNotEquals["sts:SourceIdentity"] == "osra-codex-mac" &&
      toset(one([for statement in jsondecode(aws_iam_policy.mac_phase1_ceiling.policy).Statement : statement if statement.Sid == "OnlyMappedRoleTargets"]).NotResource) == toset(values(local.mac_phase1_role_arns)) &&
      alltrue([for statement in local.production_entry_agent_trust_statements : toset(statement.Principal.AWS) == toset([local.agent_user_arns["osra-codex-mac"]])])
    )
    error_message = "entry must use reviewed role aliases and the exact Mac identity without changing the PC trust path"
  }
}
