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
  description = "Deployment environment used in resource names and tags."
  type        = string
  default     = "staging"
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
