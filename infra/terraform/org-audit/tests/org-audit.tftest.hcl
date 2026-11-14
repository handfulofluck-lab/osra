# Plan-only checks with mock providers: no AWS credentials, nothing is created.

mock_provider "aws" {
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
}

mock_provider "aws" {
  alias = "us_east_1"
}

variables {
  management_account_id = "000000000000"
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
