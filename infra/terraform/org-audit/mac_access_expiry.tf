# Draft local enforcement preparation (#893). This scheduled cleanup is not an exact-second access
# cutoff or STS revocation. Follow the approved private operating procedure before use.
locals {
  mac_expiry_name         = "osra-mac-expiry"
  mac_expiry_function_arn = "arn:aws:lambda:${var.region}:${local.account_id}:function:${local.mac_expiry_name}"
  mac_expiry_role_arn     = "arn:aws:iam::${local.account_id}:role/${local.mac_expiry_name}"
  mac_expiry_policy_arn   = "arn:aws:iam::${local.account_id}:policy/${local.mac_expiry_name}"
  mac_expiry_log_arn      = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/${local.mac_expiry_name}"
  mac_expiry_rule_arn     = "arn:aws:events:${var.region}:${local.account_id}:rule/${local.mac_expiry_name}"

  # Scoped name prefixes include function versions and log streams, not other accounts or users.
  mac_expiry_resource_arns = [
    "${local.mac_expiry_function_arn}*", local.mac_expiry_role_arn, local.mac_expiry_policy_arn,
    "${local.mac_expiry_log_arn}*", local.mac_expiry_rule_arn,
  ]

  mac_expiry_execution_statements = [
    {
      Sid      = "OnlyMacKeyStatusAndMetadata"
      Effect   = "Allow"
      Action   = ["iam:ListUserTags", "iam:ListAccessKeys", "iam:UpdateAccessKey"]
      Resource = local.agent_user_arns["osra-codex-mac"]
    },
    {
      Sid      = "OnlyItsStatusLog"
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${local.mac_expiry_log_arn}:*"
    },
  ]
}

# Dedicated narrow boundary: the general management-role boundary still denies key management to
# roles. No role-wide exception is added there. Only Karim's approved MFA apply provisions this role.
resource "aws_iam_policy" "mac_expiry_boundary" {
  name        = local.mac_expiry_name
  description = "Maximum permissions for the Mac authorization-expiry job; no keys, tags, secrets or backups are created or deleted."
  policy      = jsonencode({ Version = "2012-10-17", Statement = local.mac_expiry_execution_statements })
}

resource "aws_iam_role" "mac_expiry" {
  name                 = local.mac_expiry_name
  permissions_boundary = aws_iam_policy.mac_expiry_boundary.arn
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "mac_expiry" {
  name   = "expire-only-mac-access"
  role   = aws_iam_role.mac_expiry.id
  policy = jsonencode({ Version = "2012-10-17", Statement = local.mac_expiry_execution_statements })
}

resource "aws_cloudwatch_log_group" "mac_expiry" {
  name              = "/aws/lambda/${local.mac_expiry_name}"
  retention_in_days = var.access_log_retention_days
}

data "archive_file" "mac_expiry" {
  type        = "zip"
  source_file = "${path.module}/functions/agent_access_expiry.py"
  output_path = "${path.module}/.terraform/mac-access-expiry.zip"
}

resource "aws_lambda_function" "mac_expiry" {
  function_name                  = local.mac_expiry_name
  description                    = "Disable every current Mac key at the protected authorization deadline; not STS revocation."
  role                           = aws_iam_role.mac_expiry.arn
  runtime                        = "python3.13"
  handler                        = "agent_access_expiry.handler"
  filename                       = data.archive_file.mac_expiry.output_path
  source_code_hash               = data.archive_file.mac_expiry.output_base64sha256
  timeout                        = 30
  memory_size                    = 128
  reserved_concurrent_executions = 1

  depends_on = [aws_iam_role_policy.mac_expiry, aws_cloudwatch_log_group.mac_expiry, aws_iam_user.codex_mac]
}

# Reuse this stack's existing EventBridge-rule pattern and resource-policy invocation. AWS calls
# scheduled rules a legacy facility; their minute resolution and delivery delay are explicit here.
resource "aws_cloudwatch_event_rule" "mac_expiry" {
  name                = local.mac_expiry_name
  description         = "Recheck the fixed authorization tag and current keys every minute."
  schedule_expression = "rate(1 minute)"
  state               = "ENABLED"
}

resource "aws_lambda_permission" "mac_expiry" {
  statement_id   = "OnlyExpiryRule"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.mac_expiry.function_name
  principal      = "events.amazonaws.com"
  source_arn     = aws_cloudwatch_event_rule.mac_expiry.arn
  source_account = local.account_id
}

resource "aws_cloudwatch_event_target" "mac_expiry" {
  rule      = aws_cloudwatch_event_rule.mac_expiry.name
  target_id = "disable-expired-mac-keys"
  arn       = aws_lambda_function.mac_expiry.arn

  retry_policy {
    maximum_event_age_in_seconds = 60
    maximum_retry_attempts       = 2
  }

  depends_on = [aws_lambda_permission.mac_expiry]
}

resource "aws_cloudwatch_log_metric_filter" "mac_expiry_failure" {
  name           = "mac-authorization-expiry-failure"
  log_group_name = aws_cloudwatch_log_group.mac_expiry.name
  pattern        = "{ ($.errors > 0) || ($.invalid_deadline > 0) }"

  metric_transformation {
    name          = "MacAuthorizationExpiryFailure"
    namespace     = "OSRA/Access"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "mac_expiry_failure" {
  alarm_name          = "osra-mac-expiry-failure"
  alarm_description   = "The expiry job found an invalid authorization deadline or incomplete enforcement."
  namespace           = "OSRA/Access"
  metric_name         = "MacAuthorizationExpiryFailure"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.access_alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "mac_expiry_health" {
  for_each            = { missing = "Invocations", runtime = "Errors" }
  alarm_name          = "osra-mac-expiry-${each.key}"
  alarm_description   = "Mac authorization expiry job health; a key-disable job is not a session-revocation control."
  namespace           = "AWS/Lambda"
  metric_name         = each.value
  dimensions          = { FunctionName = aws_lambda_function.mac_expiry.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = each.key == "missing" ? "LessThanThreshold" : "GreaterThanOrEqualToThreshold"
  treat_missing_data  = each.key == "missing" ? "breaching" : "notBreaching"
  alarm_actions       = [aws_sns_topic.access_alarms.arn]
}
