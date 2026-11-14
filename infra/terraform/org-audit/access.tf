# --- Production access (#766 item 7; Karim's decision, 14 Nov 2026, 21:17 UAE, final) -----------------
# People sign in through IAM Identity Center with MFA. The agents (Claude and Kimi, through the AWS MCP
# server and Terraform on Karim's PC) keep ONE permanent management-account credential with full rights,
# no MFA and no expiry, so they are never locked out ("i dont want that you are locked out and need me to
# help you get acess again"). This is a written owner exception to "no long-lived keys" (#637 comments
# 6881323682 and 6881341115). What stands in for the expiry:
#   1. every call the key makes, in any account of the organisation, reaches this trail's log group;
#   2. an alarm emails both alarm addresses when the key, or a session it assumed, is used from an address
#      outside `agent_trusted_ip_prefixes`, and whenever anyone creates, disables or deletes one of its keys;
#   3. rotate-agent-key.sh replaces the key without a gap (new key first, old one deleted after the new one
#      works), so rotation never needs Karim.

variable "agent_user_name" {
  description = "IAM user (management account) whose access key the agents use."
  type        = string
  default     = "osra-staging-deployer"
}

variable "agent_trusted_ip_prefixes" {
  description = "Source-address prefixes the agent key is expected from (Karim's PC's ISP), e.g. [\"41.\"]. A call from anywhere else alarms; it is NOT blocked, so an address change never locks the agents out."
  type        = list(string)

  validation {
    condition     = length(var.agent_trusted_ip_prefixes) > 0 && alltrue([for p in var.agent_trusted_ip_prefixes : can(regex("^[0-9]{1,3}\\.([0-9]{1,3}\\.){0,2}$", p))])
    error_message = "Give at least one IPv4 prefix ending in a dot, e.g. \"41.\" or \"41.40.\"."
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

  # The user itself, or a session assumed into any member account's OrganizationAccountAccessRole (how the
  # agents reach osra-production and staging).
  agent_principal_clause = "(($.userIdentity.arn = \"${local.agent_user_arn}\") || ($.userIdentity.arn = \"*:assumed-role/OrganizationAccountAccessRole/*\"))"

  agent_key_changes = "(($.eventName = \"CreateAccessKey\") || ($.eventName = \"UpdateAccessKey\") || ($.eventName = \"DeleteAccessKey\")) && ($.requestParameters.userName = \"${var.agent_user_name}\")"
}

# --- The trail's CloudWatch Logs copy -------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "trail" {
  name              = "/osra/org-trail"
  retention_in_days = var.access_log_retention_days
}

resource "aws_iam_role" "trail_to_logs" {
  name = "osra-org-trail-to-logs"
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
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
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
      Sid       = "CloudWatchAlarms"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
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
  alarm_description   = "The agents' permanent key (or a session it assumed) was used from outside Karim's PC's network. Check the org trail log group /osra/org-trail for the source address; if it is not Karim's new address, rotate the key (rotate-agent-key.sh) at once."
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
  alarm_description   = "A key of the agents' IAM user was created, disabled or deleted. Expected during rotate-agent-key.sh; anything else is an incident."
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

output "access_alarms_topic_arn" {
  value = aws_sns_topic.access_alarms.arn
}
