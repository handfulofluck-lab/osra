# Local Phase 1 preparation (#893), pending independent review and private operating prerequisites.
variable "mac_access_expires_at" {
  description = "Fixed ISO authorization deadline set only by the owner's approved MFA session; rotation never changes it."
  type        = string

  validation {
    condition     = can(formatdate("YYYY-MM-DD'T'hh:mm:ssZ", var.mac_access_expires_at))
    error_message = "Supply the privately approved fixed ISO authorization deadline."
  }
}

resource "aws_iam_user" "codex_mac" {
  name                 = "osra-codex-mac"
  permissions_boundary = aws_iam_policy.role_boundary.arn
  force_destroy        = false
  tags                 = { "osra:access-expires-at" = var.mac_access_expires_at }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_cloudwatch_log_metric_filter" "agent_key_unexpected_source_by_user" {
  for_each       = toset(var.agent_user_names)
  name           = "osra-agent-key-unexpected-source-${each.key}"
  log_group_name = aws_cloudwatch_log_group.trail.name
  pattern        = "{ ${local.agent_principal_clauses[each.key]} && ${local.agent_ip_clauses_by_user[each.key]} }"

  metric_transformation {
    name          = "AgentKeyUnexpectedSource-${each.key}"
    namespace     = "OSRA/Access"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "agent_key_unexpected_source_by_user" {
  for_each            = toset(var.agent_user_names)
  alarm_name          = "osra-agent-key-unexpected-source-${each.key}"
  alarm_description   = "${each.key} or its SourceIdentity-attributed session was used outside its trusted prefixes; the legacy umbrella remains."
  namespace           = "OSRA/Access"
  metric_name         = "AgentKeyUnexpectedSource-${each.key}"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.access_alarms.arn]
}

# The entry role is not owned by this stack. These statements must be merged into its reviewed current
# trust under the owner's MFA session; emitting them must not replace unseen non-agent trust statements.
# Review both the explicit Deny and Allow against the approved current trust before installation.
locals {
  production_entry_agent_trust_statements = [
    {
      Sid       = "AgentSourceIdentityRequired"
      Effect    = "Deny"
      Principal = { AWS = [local.agent_user_arns["osra-codex-mac"]] }
      Action    = ["sts:AssumeRole", "sts:SetSourceIdentity"]
      Condition = { StringNotEquals = { "sts:SourceIdentity" = "$${aws:username}" } }
    },
    {
      Sid       = "AgentSourceIdentity"
      Effect    = "Allow"
      Principal = { AWS = [local.agent_user_arns["osra-codex-mac"]] }
      Action    = ["sts:AssumeRole", "sts:SetSourceIdentity"]
      Condition = { StringEquals = { "sts:SourceIdentity" = "$${aws:username}" } }
    },
  ]
}

output "production_entry_agent_trust_additions" {
  description = "Review/merge these statements with the actual production entry role trust before agent use; not an applied trust policy."
  value       = jsonencode({ Version = "2012-10-17", Statement = local.production_entry_agent_trust_statements })
  sensitive   = true
}
