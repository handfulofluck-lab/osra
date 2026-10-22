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

output "demo_password_secret_arn" {
  description = "ARN of the Secrets Manager entry holding the seeded demo parent's password (env injects it as SEED_DEMO_PASSWORD)."
  value       = aws_secretsmanager_secret.demo_password.arn
}

output "execution_role_arn" {
  description = "ECS task execution role env's task definition runs as."
  value       = aws_iam_role.execution.arn
}

output "publish_role_arn" {
  description = "Role GitHub Actions assumes over OIDC to push the API image (empty when github_repo is unset)."
  value       = var.github_repo != "" ? aws_iam_role.publish[0].arn : ""
}

output "certificate_arn" {
  description = "ACM certificate for the ALB, or empty in non-release (HTTP-only) mode."
  value       = local.certificate_arn
}

output "domain_name" {
  description = "Public hostname the API is served on, or empty in non-release mode."
  value       = var.domain_name
}

output "hosted_zone_id" {
  description = "Route 53 zone that holds the API record, or empty when no hosted_zone_name is set (env then creates no record)."
  value       = var.hosted_zone_name != "" ? data.aws_route53_zone.main[0].zone_id : ""
}

output "log_group_name" {
  description = "CloudWatch log group the API container writes to."
  value       = aws_cloudwatch_log_group.api.name
}
