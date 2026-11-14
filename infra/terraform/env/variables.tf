variable "region" {
  description = "AWS region for this regional stack (ADR-0028: one independent stack per market)."
  type        = string
  default     = "eu-north-1"
}

variable "project" {
  description = "Project name used in resource names and tags."
  type        = string
  default     = "osra"
}

variable "environment" {
  description = "Deployment environment used in resource names and tags. \"production\" arms production_guard.tf; up.sh passes it explicitly for production runs."
  type        = string
  default     = "staging"

  # A misspelling ("prod") would otherwise skip the production guard entirely (Fable, #765 re-review).
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be exactly staging or production."
  }
}

variable "api_image" {
  description = "Full API image reference including tag, e.g. <account>.dkr.ecr.eu-north-1.amazonaws.com/osra-staging/api:staging. Deliberately has no default so a stack can never deploy an accidental image."
  type        = string

  validation {
    condition     = length(trimspace(var.api_image)) > 0
    error_message = "api_image must be a non-empty container image reference."
  }
}

variable "api_cpu" {
  description = "Fargate task CPU units (1024 = 1 vCPU). 512 = 0.5 vCPU."
  type        = number
  default     = 512

  validation {
    condition     = contains([256, 512, 1024, 2048, 4096], var.api_cpu)
    error_message = "api_cpu must be one of the Fargate CPU values: 256, 512, 1024, 2048, 4096."
  }
}

variable "api_memory" {
  description = "Fargate task memory in MiB. 1024 pairs with cpu = 512 (ADR-0028's minimum-size API task)."
  type        = number
  default     = 1024

  validation {
    condition     = var.api_memory >= 512 && var.api_memory <= 30720
    error_message = "api_memory must be between 512 and 30720 MiB."
  }
}

variable "api_service_enabled" {
  description = "Create the ECS service. up.sh applies with this false, seeds the database, then applies again — the API exits at boot on an empty schema and Terraform waits for a service to stabilise."
  type        = bool
  default     = true
}

variable "db_instance_class" {
  description = "RDS PostgreSQL instance class. db.t4g.micro is the cheapest Graviton class that supports Multi-AZ."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_multi_az" {
  description = "Run a standby in a second AZ. Off for on-demand staging: a test run gains nothing from a standby and it is the slowest part of an apply. Production MUST set this to true."
  type        = bool
  default     = false
}

variable "redis_node_type" {
  description = "ElastiCache node type (ADR-0028 names ElastiCache Valkey for fan-out and revocation flags)."
  type        = string
  default     = "cache.t4g.micro"
}

variable "allowed_cidrs" {
  description = "CIDR ranges allowed to reach the ALB. Default is public because release-mode staging serves test builds; in non-release mode 0.0.0.0/0 is refused because port 80 would carry the API in cleartext."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.allowed_cidrs) > 0
    error_message = "allowed_cidrs must contain at least one CIDR."
  }
}

variable "cors_origin" {
  description = "Optional comma-separated CORS allowlist for browser callers. Empty leaves the API's permissive staging default, so set it once the parent web app has an origin."
  type        = string
  default     = ""
}

variable "push_enabled" {
  description = "Map the FCM service account secret into the API task (roadmap 1.5). Set it only after the secret has a value: ECS cannot resolve a secret with no version, and the task would fail to start."
  type        = bool
  default     = false
}

# --- Account wiring (issue #714). Staging leaves all of these at their defaults. ---

variable "assume_role_arn" {
  description = "Role the provider (and the backend file) assumes. Empty in staging; production names the deploy role inside osra-production."
  type        = string
  default     = ""

  validation {
    condition     = var.assume_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.assume_role_arn))
    error_message = "assume_role_arn must be empty or an IAM role ARN."
  }
}

variable "allowed_account_ids" {
  description = "Account IDs this stack may touch. Empty = no check (staging). Production pins its own account so a wrong profile fails before planning."
  type        = list(string)
  default     = []
}

variable "state_bucket" {
  description = "Bucket holding base's state (must match backend/<env>-base.hcl)."
  type        = string
  default     = "osra-terraform-state-222207908538-eu-north-1"
}

variable "state_region" {
  description = "Region of state_bucket."
  type        = string
  default     = "eu-north-1"
}

variable "base_state_key" {
  description = "Key of base's state in state_bucket."
  type        = string
  default     = "staging/base/terraform.tfstate"
}

# --- Production settings (issue #714): every default is today's staging value. ---

variable "nat_gateway_count" {
  description = "NAT gateways: 1 (staging, cost over HA) or 2 (production, one per AZ so losing an AZ does not cut the tasks' outbound path to Secrets Manager, ECR and FCM)."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2], var.nat_gateway_count)
    error_message = "nat_gateway_count must be 1 or 2."
  }
}

variable "db_allocated_storage" {
  description = "RDS gp3 storage in GiB."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Storage autoscaling ceiling in GiB; 0 turns autoscaling off (staging)."
  type        = number
  default     = 0
}

variable "db_backup_retention_days" {
  description = "Automated backups and point-in-time restore window. 0 in throwaway staging; production MUST be above 0 (14)."
  type        = number
  default     = 0

  validation {
    condition     = var.db_backup_retention_days >= 0 && var.db_backup_retention_days <= 35
    error_message = "db_backup_retention_days must be 0-35."
  }
}

variable "db_deletion_protection" {
  description = "RDS deletion protection. Off so staging's `down` is one command; production MUST be on."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. True for staging; production MUST be false."
  type        = bool
  default     = true
}

variable "db_performance_insights" {
  description = "Performance Insights (7-day retention, the free tier). Off in staging."
  type        = bool
  default     = false
}

variable "db_backup_window" {
  description = "Daily UTC backup window (hh24:mi-hh24:mi) or null for AWS's choice. Production: 23:00-23:30 UTC = 03:00 UAE."
  type        = string
  default     = null
}

variable "db_maintenance_window" {
  description = "Weekly UTC maintenance window (ddd:hh24:mi-ddd:hh24:mi) or null for AWS's choice."
  type        = string
  default     = null
}

variable "redis_num_nodes" {
  description = "Cache nodes in the replication group: 1 in staging, 2 (primary + replica in another AZ) in production."
  type        = number
  default     = 1

  validation {
    condition     = var.redis_num_nodes >= 1 && var.redis_num_nodes <= 3
    error_message = "redis_num_nodes must be 1-3."
  }
}

variable "redis_failover" {
  description = "Automatic failover and Multi-AZ for the cache. Needs redis_num_nodes >= 2."
  type        = bool
  default     = false

  validation {
    condition     = !var.redis_failover || var.redis_num_nodes >= 2
    error_message = "redis_failover needs redis_num_nodes >= 2."
  }
}

variable "redis_transit_encryption" {
  description = "TLS between the API and the cache. The API then gets a rediss:// URL (ioredis turns TLS on for that scheme). Off in staging."
  type        = bool
  default     = false
}

variable "api_min_count" {
  description = "Minimum (and initial) API task count. ADR-0028's floor is 2."
  type        = number
  default     = 2

  validation {
    condition     = var.api_min_count >= 2
    error_message = "api_min_count must be at least 2 (ADR-0028: one task can die without an outage)."
  }
}

variable "api_max_count" {
  description = "Autoscaling ceiling for API tasks: 4 in staging, 6 in production."
  type        = number
  default     = 4

  validation {
    condition     = var.api_max_count >= var.api_min_count
    error_message = "api_max_count must be >= api_min_count."
  }
}

variable "container_insights" {
  description = "ECS Container Insights (per-metric charge). Off in staging."
  type        = bool
  default     = false
}

variable "alb_deletion_protection" {
  description = "ALB deletion protection. Off so staging's `down` works; on in production."
  type        = bool
  default     = false
}

variable "waf_enabled" {
  description = "Attach a WAFv2 web ACL to the ALB: AWS managed Common, KnownBadInputs and IP-reputation rules plus a per-IP rate rule. Off in staging."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Requests per 5 minutes per client IP before the rate rule matches."
  type        = number
  default     = 2000
}

variable "waf_rate_action" {
  description = "What the rate rule does on a match: count (first weeks, to learn real traffic) or block."
  type        = string
  default     = "count"

  validation {
    condition     = contains(["count", "block"], var.waf_rate_action)
    error_message = "waf_rate_action must be count or block."
  }
}

variable "alarms_enabled" {
  description = "Create the SNS alarm topic and the ALB, ECS, RDS and Redis alarms. Off in staging, where the Redis memory alarm still exists without an action."
  type        = bool
  default     = false
}

variable "alarm_email" {
  description = "Address subscribed to the alarm topic. Set it only in the gitignored tfvars; never commit an address. Empty = topic without subscribers."
  type        = string
  default     = ""
  sensitive   = true
}

variable "alarm_email_secondary" {
  description = "A second, different address for the same alerts, so one missed inbox cannot hide an outage (#766 item 6). Gitignored tfvars only. Production requires it."
  type        = string
  default     = ""
  sensitive   = true
}

variable "secrets_out_of_band" {
  description = "Keep secret VALUES out of Terraform state (#766 items 1 and 3): JWT_SECRET, VAULT_KEY, the API's database password and the Redis AUTH token are generated by production-secrets.sh and written straight to Secrets Manager. Production MUST be true; staging keeps Terraform-generated values so `up` stays one command."
  type        = bool
  default     = false
}

variable "app_public_url" {
  description = "Public URL of the parent web app, used in e-mail links (APP_PUBLIC_URL). Empty = not set."
  type        = string
  default     = ""
}

variable "email_provider" {
  description = "EMAIL_PROVIDER for the API (\"ses\" or \"resend\"); empty = e-mail off."
  type        = string
  default     = ""
}

variable "email_from" {
  description = "EMAIL_FROM for the API, e.g. \"OSRA <no-reply@osratech.com>\". Empty = not set."
  type        = string
  default     = ""
}

variable "audit_logs_enabled" {
  description = "ALB access logs, VPC flow logs, WAF logs and PostgreSQL log export, each kept exactly 90 days (#766 item 2). Production MUST be true; staging leaves them off."
  type        = bool
  default     = false
}
