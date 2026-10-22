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
