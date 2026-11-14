# Plan-only checks with mock providers: no AWS credentials, nothing is created.

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
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:eu-west-1:000000000000:key/copy"
    }
  }
}

variables {
  management_account_id     = "000000000000"
  production_account_id     = "111111111111"
  agent_user_name           = "test-deployer"
  agent_trusted_ip_prefixes = ["192.0.2."]
  alarm_email               = "a@example.com"
  alarm_email_secondary     = "b@example.com"
  owner_user_name           = "owner"
  owner_given_name          = "Test"
  owner_family_name         = "Owner"
  owner_email               = "owner@example.com"
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
    condition     = alltrue([for a in ["s3:BypassGovernanceRetention", "s3:PutObjectRetention", "s3:PutObjectLegalHold", "s3:PutBucketObjectLockConfiguration", "guardduty:DeleteDetector", "guardduty:CreateFilter", "events:DisableRule"] : strcontains(aws_iam_user_policy.agent_cannot_disable_watchers.policy, a)])
    error_message = "the agents' key must be denied bypassing the Object Lock and switching off management GuardDuty or its alert rules (#782)"
  }
  assert {
    condition     = aws_cloudwatch_event_target.management_guardduty_forward.arn == "arn:aws:events:eu-central-1:000000000000:event-bus/default"
    error_message = "us-east-1 GuardDuty findings must be forwarded to the home region's bus"
  }
}
