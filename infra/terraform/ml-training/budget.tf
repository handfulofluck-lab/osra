# An alert on the Purpose=ml-training tag. The tag must be activated as a cost allocation tag in the
# management account before the filter sees any spend (README). The real cap is set on each job:
# StoppingCondition.MaxRuntimeInSeconds.
resource "aws_budgets_budget" "ml" {
  name         = local.name
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Purpose$ml-training"]
  }

  dynamic "notification" {
    for_each = length(var.budget_alert_emails) > 0 ? [
      { threshold = 80, type = "ACTUAL" },
      { threshold = 100, type = "FORECASTED" },
    ] : []

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = var.budget_alert_emails
    }
  }
}
