# --- GuardDuty in the management account (#782 review) ------------------------------------------
# Production's own detector (base/guardduty.tf) watches production. The management account holds the
# organisation, the trail, Identity Center and the deployer user, so it gets its own detector:
# in the home region and in us-east-1, where IAM, Organizations and Identity Center sign-in events land.
# High findings (severity 7+) are mailed through the access alarm topic (guardduty_alerts.tf).

provider "aws" {
  alias               = "us_east_1"
  region              = "us-east-1"
  allowed_account_ids = [var.management_account_id]

  default_tags {
    tags = {
      Project   = "osra"
      ManagedBy = "terraform"
      Purpose   = "org-audit"
    }
  }
}

resource "aws_guardduty_detector" "management" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

resource "aws_guardduty_detector" "management_us_east_1" {
  provider = aws.us_east_1

  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

output "management_guardduty_detectors" {
  value = {
    (var.region) = aws_guardduty_detector.management.id
    "us-east-1"  = aws_guardduty_detector.management_us_east_1.id
  }
}
