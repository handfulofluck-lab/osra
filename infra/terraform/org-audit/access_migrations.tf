# Keep the existing PC resources and physical alarm names. The legacy source umbrella stays untouched.
moved {
  from = aws_cloudwatch_log_metric_filter.agent_key_changed
  to   = aws_cloudwatch_log_metric_filter.agent_key_changed["osra-staging-deployer"]
}
moved {
  from = aws_cloudwatch_metric_alarm.agent_key_changed
  to   = aws_cloudwatch_metric_alarm.agent_key_changed["osra-staging-deployer"]
}
moved {
  from = aws_cloudwatch_log_metric_filter.agent_new_principals
  to   = aws_cloudwatch_log_metric_filter.agent_new_principals["osra-staging-deployer"]
}
moved {
  from = aws_cloudwatch_metric_alarm.agent_new_principals
  to   = aws_cloudwatch_metric_alarm.agent_new_principals["osra-staging-deployer"]
}
moved {
  from = aws_iam_user_policy_attachment.agent_keep_watchers
  to   = aws_iam_user_policy_attachment.agent_keep_watchers["osra-staging-deployer"]
}
moved {
  from = aws_iam_user_policy_attachment.agent_keep_backups
  to   = aws_iam_user_policy_attachment.agent_keep_backups["osra-staging-deployer"]
}
moved {
  from = aws_iam_user_policy_attachment.agent_no_escalation
  to   = aws_iam_user_policy_attachment.agent_no_escalation["osra-staging-deployer"]
}
