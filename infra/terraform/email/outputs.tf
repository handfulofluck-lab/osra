output "identity_arn" {
  description = "The SES domain identity the API sends as."
  value       = aws_sesv2_email_identity.domain.arn
}

output "api_task_role_arn" {
  description = "Runtime role for the API task; env/ sets it as task_role_arn when email_enabled = true."
  value       = aws_iam_role.api_task.arn
}

output "region" {
  description = "Region of the identity; the API must run in the same region."
  value       = var.region
}
