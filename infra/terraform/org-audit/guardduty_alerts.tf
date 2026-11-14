# --- Management-account GuardDuty findings are mailed (#782 review) ----------------------------------
# Severity 7+ findings from both management detectors (guardduty.tf) go to the access alarm topic. A rule in
# us-east-1 cannot target an SNS topic in another region, so it forwards the finding to the home region's
# default event bus, where the same rule that mails home-region findings picks it up.

locals {
  guardduty_high_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail        = { severity = [{ numeric = [">=", 7] }] }
  })
}

resource "aws_cloudwatch_event_rule" "management_guardduty_high" {
  name          = "osra-management-guardduty-high"
  description   = "GuardDuty severity 7+ in the management account (home region and forwarded from us-east-1)"
  event_pattern = local.guardduty_high_pattern
}

resource "aws_cloudwatch_event_target" "management_guardduty_high" {
  rule = aws_cloudwatch_event_rule.management_guardduty_high.name
  arn  = aws_sns_topic.access_alarms.arn
}

resource "aws_iam_role" "guardduty_forward" {
  name = "osra-guardduty-forward"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "guardduty_forward" {
  name = "put-to-home-bus"
  role = aws_iam_role.guardduty_forward.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = "arn:aws:events:${var.region}:${local.account_id}:event-bus/default"
    }]
  })
}

resource "aws_cloudwatch_event_rule" "management_guardduty_forward" {
  provider = aws.us_east_1

  name          = "osra-management-guardduty-forward"
  description   = "Forwards GuardDuty severity 7+ from us-east-1 to the home region's default bus"
  event_pattern = local.guardduty_high_pattern
}

resource "aws_cloudwatch_event_target" "management_guardduty_forward" {
  provider = aws.us_east_1

  rule     = aws_cloudwatch_event_rule.management_guardduty_forward.name
  arn      = "arn:aws:events:${var.region}:${local.account_id}:event-bus/default"
  role_arn = aws_iam_role.guardduty_forward.arn
}
