# --- Family plan warnings (#811) ------------------------------------------------------------------
# The API writes one JSON line to stdout when a family's purchase is ignored for entitlement:
#   {"event":"family_plan_recovery_ceiling",...}  a grace/on-hold purchase passed the lost-push ceiling,
#                                                 so the store's renewal push probably never reached us;
#   {"event":"family_plan_missing_expiry",...}    a purchase row has no expiry date (a data bug).
# Either one means a paying family may have lost access. Each becomes a metric and an alarm that mails
# the environment's alarm topic on the first occurrence. The lines carry only the family id and a hash of
# the store reference, never a receipt.

locals {
  family_plan_events = var.alarms_enabled ? {
    "family-plan-recovery-ceiling" = {
      event       = "family_plan_recovery_ceiling"
      metric      = "FamilyPlanRecoveryCeiling"
      description = "A family's store purchase passed the grace/on-hold recovery ceiling and was dropped from entitlement (#811). Check the store's server notifications for that family."
    }
    "family-plan-missing-expiry" = {
      event       = "family_plan_missing_expiry"
      metric      = "FamilyPlanMissingExpiry"
      description = "A family purchase row has no expiry date and was ignored for entitlement (#811). A data bug: fix the row."
    }
  } : {}
}

resource "aws_cloudwatch_log_metric_filter" "family_plan" {
  for_each = local.family_plan_events

  name           = "${local.name_prefix}-${each.key}"
  log_group_name = data.terraform_remote_state.base.outputs.log_group_name
  pattern        = "{ $.event = \"${each.value.event}\" }"

  metric_transformation {
    name          = each.value.metric
    namespace     = "Osra/${local.name_prefix}"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "family_plan" {
  for_each = local.family_plan_events

  alarm_name          = "${local.name_prefix}-${each.key}"
  alarm_description   = each.value.description
  namespace           = "Osra/${local.name_prefix}"
  metric_name         = each.value.metric
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  tags = {
    Name = "${local.name_prefix}-${each.key}"
  }

  depends_on = [aws_cloudwatch_log_metric_filter.family_plan]
}
