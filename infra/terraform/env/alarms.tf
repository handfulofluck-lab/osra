# --- Alarms (production, #714) ----------------------------------------------------------------
# One SNS topic per environment; the e-mail address comes from the gitignored tfvars. AWS sends a
# confirmation mail first, and nothing is delivered until someone clicks it.

resource "aws_sns_topic" "alarms" {
  count = var.alarms_enabled ? 1 : 0

  name = "${local.name_prefix}-alarms"
  # The AWS-managed key: encrypted at rest at no extra cost; CloudWatch may publish to it.
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Name = "${local.name_prefix}-alarms"
  }
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
