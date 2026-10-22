output "ecr_repository_url" {
  description = "ECR repository to push the API image to (append :staging or a git sha)."
  value       = aws_ecr_repository.api.repository_url
}

output "database_url_secret_arn" {
  description = "ARN of the Secrets Manager entry holding DATABASE_URL (env writes its version)."
  value       = aws_secretsmanager_secret.database_url.arn
}

output "jwt_secret_arn" {
  description = "ARN of the Secrets Manager entry holding JWT_SECRET."
  value       = aws_secretsmanager_secret.jwt_secret.arn
}

output "vault_key_secret_arn" {
  description = "ARN of the Secrets Manager entry holding VAULT_KEY."
  value       = aws_secretsmanager_secret.vault_key.arn
}

output "execution_role_arn" {
  description = "ECS task execution role env's task definition runs as."
  value       = aws_iam_role.execution.arn
}

output "certificate_arn" {
  description = "ACM certificate for the ALB, or empty in non-release (HTTP-only) mode."
  value       = local.certificate_arn
}

output "log_group_name" {
  description = "CloudWatch log group the API container writes to."
  value       = aws_cloudwatch_log_group.api.name
}
