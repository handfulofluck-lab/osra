# --- Alarms (production, #714) ----------------------------------------------------------------
# One SNS topic per environment; the e-mail address comes from the gitignored tfvars. AWS sends a
# confirmation mail first, and nothing is delivered until someone clicks it.

# CloudWatch alarms and EventBridge cannot publish to a topic encrypted with the AWS-managed aws/sns key:
# that key's policy cannot be changed to let them use it, so every alarm notification would be dropped
# without an error. A customer key whose policy names both services fixes it (found in #766 batch C).
resource "aws_kms_key" "alarms" {
  count = var.alarms_enabled ? 1 : 0

  description         = "${local.name_prefix} alarm topic"
  enable_key_rotation = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountAdministers"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AlarmPublishers"
        Effect    = "Allow"
        Principal = { Service = ["cloudwatch.amazonaws.com", "events.amazonaws.com"] }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "alarms" {
  count = var.alarms_enabled ? 1 : 0

  name          = "alias/${local.name_prefix}-alarms"
  target_key_id = aws_kms_key.alarms[0].key_id
}

resource "aws_sns_topic" "alarms" {
  count = var.alarms_enabled ? 1 : 0

  name              = "${local.name_prefix}-alarms"
  kms_master_key_id = aws_kms_key.alarms[0].arn

  tags = {
    Name = "${local.name_prefix}-alarms"
  }
}

resource "aws_sns_topic_subscription" "alarms_email_secondary" {
  count = var.alarms_enabled && var.alarm_email_secondary != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email_secondary
}

resource "aws_sns_topic_subscription" "alarms_email" {
  count = var.alarms_enabled && var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  # name => alarm. Every threshold is a starting point, to be tuned from the first weeks of traffic.
  alarms = var.alarms_enabled ? merge(
    {
      "alb-target-5xx" = {
        description = "API answered 5xx more than 20 times in 5 minutes."
        namespace   = "AWS/ApplicationELB"
        metric      = "HTTPCode_Target_5XX_Count"
        statistic   = "Sum"
        threshold   = 20
        operator    = "GreaterThanThreshold"
        periods     = 1
        dimensions  = { LoadBalancer = aws_lb.main.arn_suffix }
      }
      "alb-elb-5xx" = {
        description = "The load balancer itself answered 5xx (no healthy task, or a task timed out) more than 10 times in 5 minutes."
        namespace   = "AWS/ApplicationELB"
        metric      = "HTTPCode_ELB_5XX_Count"
        statistic   = "Sum"
        threshold   = 10
        operator    = "GreaterThanThreshold"
        periods     = 1
        dimensions  = { LoadBalancer = aws_lb.main.arn_suffix }
      }
      "alb-unhealthy-targets" = {
        description = "At least one API task failed its health check for 10 minutes."
        namespace   = "AWS/ApplicationELB"
        metric      = "UnHealthyHostCount"
        statistic   = "Maximum"
        threshold   = 0
        operator    = "GreaterThanThreshold"
        periods     = 2
        dimensions  = { LoadBalancer = aws_lb.main.arn_suffix, TargetGroup = aws_lb_target_group.api.arn_suffix }
      }
      "rds-cpu" = {
        description = "PostgreSQL CPU above 80% for 15 minutes."
        namespace   = "AWS/RDS"
        metric      = "CPUUtilization"
        statistic   = "Average"
        threshold   = 80
        operator    = "GreaterThanThreshold"
        periods     = 3
        dimensions  = { DBInstanceIdentifier = aws_db_instance.main.identifier }
      }
      "rds-free-storage" = {
        description = "PostgreSQL free storage below 5 GiB (autoscaling should have grown it first)."
        namespace   = "AWS/RDS"
        metric      = "FreeStorageSpace"
        statistic   = "Minimum"
        threshold   = 5368709120
        operator    = "LessThanThreshold"
        periods     = 1
        dimensions  = { DBInstanceIdentifier = aws_db_instance.main.identifier }
      }
      "rds-connections" = {
        description = "PostgreSQL connections above 120: each task's Prisma pool is 10, so this means far more tasks than expected or leaking pools."
        namespace   = "AWS/RDS"
        metric      = "DatabaseConnections"
        statistic   = "Maximum"
        threshold   = 120
        operator    = "GreaterThanThreshold"
        periods     = 2
        dimensions  = { DBInstanceIdentifier = aws_db_instance.main.identifier }
      }
    },
    var.api_service_enabled ? {
      "ecs-cpu" = {
        description = "API tasks' average CPU above 85% for 15 minutes (autoscaling targets 60%, so it is at its ceiling)."
        namespace   = "AWS/ECS"
        metric      = "CPUUtilization"
        statistic   = "Average"
        threshold   = 85
        operator    = "GreaterThanThreshold"
        periods     = 3
        dimensions  = { ClusterName = aws_ecs_cluster.main.name, ServiceName = aws_ecs_service.api[0].name }
      }
      "ecs-memory" = {
        description = "API tasks' average memory above 85% for 15 minutes."
        namespace   = "AWS/ECS"
        metric      = "MemoryUtilization"
        statistic   = "Average"
        threshold   = 85
        operator    = "GreaterThanThreshold"
        periods     = 3
        dimensions  = { ClusterName = aws_ecs_cluster.main.name, ServiceName = aws_ecs_service.api[0].name }
      }
    } : {},
  ) : {}
}

resource "aws_cloudwatch_metric_alarm" "this" {
  for_each = local.alarms

  alarm_name          = "${local.name_prefix}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  period              = 300
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = each.value.operator
  treat_missing_data  = "notBreaching"
  dimensions          = each.value.dimensions
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = {
    Name = "${local.name_prefix}-${each.key}"
  }
}

# CloudWatch alarms and EventBridge (GuardDuty findings below) may publish; nothing else.
resource "aws_sns_topic_policy" "alarms" {
  count = var.alarms_enabled ? 1 : 0

  arn = aws_sns_topic.alarms[0].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AccountOwns"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = ["sns:GetTopicAttributes", "sns:SetTopicAttributes", "sns:Subscribe", "sns:ListSubscriptionsByTopic", "sns:Publish"]
        Resource  = aws_sns_topic.alarms[0].arn
      },
      {
        Sid       = "AlarmPublishers"
        Effect    = "Allow"
        Principal = { Service = ["cloudwatch.amazonaws.com", "events.amazonaws.com"] }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alarms[0].arn
        Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
      },
    ]
  })
}

# --- GuardDuty (production, #766 item 2) --------------------------------------------------------
# The detector itself lives in base (base/guardduty.tf). Findings of severity 7 or more reach the same
# two addresses as the alarms.
resource "aws_cloudwatch_event_rule" "guardduty_high" {
  count = var.alarms_enabled && local.audit_logs_enabled ? 1 : 0

  name        = "${local.name_prefix}-guardduty-high"
  description = "GuardDuty findings of severity 7 or more"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail        = { severity = [{ numeric = [">=", 7] }] }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_high" {
  count = var.alarms_enabled && local.audit_logs_enabled ? 1 : 0

  rule = aws_cloudwatch_event_rule.guardduty_high[0].name
  arn  = aws_sns_topic.alarms[0].arn
}
