# Production's monthly cost alarm (#714; Karim chose "Full from day one" at ~US$315/month with an alarm
# near US$400). Off in staging, whose `osra-monthly` budget was made by hand in the management account.
# The first two budgets in an account are free.
resource "aws_budgets_budget" "monthly" {
  count = var.budget_limit_usd > 0 ? 1 : 0

  name         = "${local.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Forecast first: it warns mid-month, while there is still time to act.
  dynamic "notification" {
    for_each = var.alarm_email != "" ? [
      { type = "FORECASTED", threshold = 100 },
      { type = "ACTUAL", threshold = 80 },
      { type = "ACTUAL", threshold = 100 },
    ] : []
    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.type
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = compact([var.alarm_email, var.alarm_email_secondary])
    }
  }
}
