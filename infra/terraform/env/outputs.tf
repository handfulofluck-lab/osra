output "alb_dns_name" {
  description = "Public DNS name of the ALB."
  value       = aws_lb.main.dns_name
}

output "api_url" {
  description = "Base URL to reach the API: the release-mode hostname once a DNS record points at the ALB, otherwise the ALB's own DNS name."
  value       = local.https_enabled && local.dns_record_enabled ? "https://${local.domain_name}" : "http://${aws_lb.main.dns_name}"
}

output "cluster_name" {
  description = "ECS cluster name (use it with `aws ecs` commands, including the seed task)."
  value       = aws_ecs_cluster.main.name
}

output "service_name" {
  description = "ECS service name (empty until api_service_enabled is applied)."
  value       = try(aws_ecs_service.api[0].name, "")
}

output "task_definition_arn" {
  description = "Current API task definition; the seed step runs it with a command override."
  value       = aws_ecs_task_definition.api.arn
}

output "private_subnet_ids" {
  description = "Comma-separated private subnet ids for `aws ecs run-task --network-configuration`."
  value       = join(",", aws_subnet.private[*].id)
}

output "api_security_group_id" {
  description = "Security group the one-off seed task joins so it can reach RDS."
  value       = aws_security_group.api.id
}

output "rds_endpoint" {
  description = "PostgreSQL host only (no port, no credentials)."
  value       = aws_db_instance.main.address
}

output "redis_endpoint" {
  description = "ElastiCache host (no port, no credentials)."
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "database_url_secret_arn" {
  description = "ARN of the Secrets Manager entry whose current version holds DATABASE_URL."
  value       = data.terraform_remote_state.base.outputs.database_url_secret_arn
}

output "alarm_topic_arn" {
  description = "SNS topic the production alarms publish to (empty when alarms are off)."
  value       = var.alarms_enabled ? aws_sns_topic.alarms[0].arn : ""
}

output "deploy_role_arn" {
  description = "Role up.sh's production CLI steps assume (the same one the provider assumes); empty in staging."
  value       = var.assume_role_arn
}

output "allowed_account_id" {
  description = "The one account production may touch; up.sh checks the CLI's identity against it."
  value       = length(var.allowed_account_ids) == 1 ? var.allowed_account_ids[0] : ""
}

output "rds_identifier" {
  description = "RDS instance identifier (up.sh snapshots it before a production migration)."
  value       = aws_db_instance.main.identifier
}

output "log_group_name" {
  description = "CloudWatch log group of the API container (base's, passed through for up.sh)."
  value       = data.terraform_remote_state.base.outputs.log_group_name
}

output "db_admin_task_definition_arn" {
  description = "One-off task that migrates as the master user and grants osra_api (production; empty otherwise)."
  value       = one(aws_ecs_task_definition.db_admin[*].arn)
}

output "redis_replication_group_id" {
  description = "ElastiCache replication group id (production-secrets.sh sets its AUTH token)."
  value       = aws_elasticache_replication_group.main.replication_group_id
}

output "redis_primary_endpoint" {
  description = "ElastiCache primary endpoint (production-secrets.sh writes it into the REDIS_URL secret)."
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "region" {
  description = "Region of this stack."
  value       = var.region
}
