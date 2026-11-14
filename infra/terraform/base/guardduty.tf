# --- GuardDuty (production, #766 item 2) --------------------------------------------------------
# Threat detection over this account's CloudTrail, VPC flow and DNS logs, plus RDS login activity and
# S3 data events. Findings are kept by GuardDuty for 90 days; severity 7+ is mailed via env/alarms.tf.
resource "aws_guardduty_detector" "main" {
  count = var.guardduty_enabled ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = {
    Name = "${local.name_prefix}-guardduty"
  }
}

resource "aws_guardduty_detector_feature" "rds_login" {
  count = var.guardduty_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.main[0].id
  name        = "RDS_LOGIN_EVENTS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "s3_data" {
  count = var.guardduty_enabled ? 1 : 0

  detector_id = aws_guardduty_detector.main[0].id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}
