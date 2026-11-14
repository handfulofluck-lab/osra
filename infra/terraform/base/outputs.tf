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
  value       = one(aws_secretsmanager_secret.demo_password[*].arn)
}

output "execution_role_arn" {
  description = "ECS task execution role env's task definition runs as."
  value       = aws_iam_role.execution.arn
}

output "publish_role_arn" {
  description = "Role GitHub Actions assumes over OIDC to push the API image (empty unless the OIDC role exists)."
  # The same condition the resources use: github_repo alone is not enough now that the subject needs the
  # numeric IDs, and indexing [0] while count is 0 fails the plan with "Invalid index".
  value = local.github_oidc_enabled ? aws_iam_role.publish[0].arn : ""
}

output "bedrock_eval_role_arn" {
  description = "Role ai-eval-bedrock.yml assumes over OIDC to measure candidate models (ADR-0033); empty unless OIDC is configured."
  value       = local.bedrock_eval_enabled ? aws_iam_role.bedrock_eval[0].arn : ""
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
  value       = local.hosted_zone_id
}

output "log_group_name" {
  description = "CloudWatch log group the API container writes to."
  value       = aws_cloudwatch_log_group.api.name
}

output "fcm_service_account_secret_arn" {
  description = "Secret holding the FCM service account JSON; its value is written out of band, never by Terraform."
  value       = aws_secretsmanager_secret.fcm_service_account.arn
}

output "hosted_zone_name_servers" {
  description = "Name servers of the zone created here (production). The parent zone needs an NS record for hosted_zone_name with these four values; empty when no zone is created."
  value       = var.create_hosted_zone ? aws_route53_zone.api[0].name_servers : []
}

output "internal_hmac_secret_arn" {
  description = "Secret holding INTERNAL_HMAC_SECRET (production); empty when the stack creates none."
  value       = var.internal_hmac_secret_enabled ? aws_secretsmanager_secret.internal_hmac_secret[0].arn : ""
}

output "internal_hmac_secret_fingerprint" {
  description = "First 12 hex characters of SHA-256 of INTERNAL_HMAC_SECRET, for the #637 evidence (shows it differs from any exposed value without revealing it). 48 bits of a hash of a 64-character random value reveal nothing usable, hence nonsensitive()."
  value       = var.internal_hmac_secret_enabled ? nonsensitive(substr(sha256(random_password.internal_hmac[0].result), 0, 12)) : ""
}

output "execution_role_name" {
  description = "Name of the ECS task execution role (env adds read access to the RDS-managed master secret for the db-admin task)."
  value       = aws_iam_role.execution.name
}

output "api_db_password_secret_arn" {
  description = "Secret holding the osra_api database password (null unless secrets_out_of_band)."
  value       = one(aws_secretsmanager_secret.api_db_password[*].arn)
}

output "redis_auth_token_secret_arn" {
  description = "Secret holding the ElastiCache AUTH token (null unless secrets_out_of_band)."
  value       = one(aws_secretsmanager_secret.redis_auth_token[*].arn)
}

output "redis_url_secret_arn" {
  description = "Secret holding REDIS_URL with the AUTH token (null unless secrets_out_of_band)."
  value       = one(aws_secretsmanager_secret.redis_url[*].arn)
}
