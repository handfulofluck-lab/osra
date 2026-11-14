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

variable "domain_name" {
  description = "Public hostname the API certificate is issued for. Empty keeps the stack in non-release (HTTP-only) mode."
  type        = string
  default     = ""
}

variable "hosted_zone_name" {
  description = "Route 53 zone that holds the certificate validation records. Required only when a certificate is created here."
  type        = string
  default     = ""

  # A certificate created here needs somewhere to publish its validation records.
  validation {
    condition     = var.domain_name == "" || var.certificate_arn != "" || var.hosted_zone_name != ""
    error_message = "hosted_zone_name is required when domain_name is set and certificate_arn is empty."
  }
}

variable "github_repo" {
  description = "GitHub repository allowed to publish the API image over OIDC, as owner/repo. Empty disables the OIDC provider and role."
  type        = string
  default     = ""

  validation {
    condition     = var.github_repo == "" || can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must be empty or owner/repo."
  }
}

// The numeric IDs are what make the OIDC subject immutable: without them a deleted and re-registered
// owner or repository name can mint a token that matches. Values do not change for the life of the repo.
variable "github_owner_id" {
  description = "Numeric GitHub owner ID for the immutable OIDC subject (gh api repos/OWNER/REPO --jq .owner.id)."
  type        = string
  default     = ""

  validation {
    condition     = var.github_owner_id == "" || can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be numeric."
  }

  # A half-filled pair would quietly create no role; fail with the command that fills it instead.
  validation {
    condition     = (var.github_repo == "") == (var.github_owner_id == "")
    error_message = "Set github_repo, github_owner_id and github_repo_id together (gh api repos/OWNER/REPO --jq '.owner.id, .id')."
  }
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID for the immutable OIDC subject (gh api repos/OWNER/REPO --jq .id)."
  type        = string
  default     = ""

  validation {
    condition     = var.github_repo_id == "" || can(regex("^[0-9]+$", var.github_repo_id))
    error_message = "github_repo_id must be numeric."
  }

  validation {
    condition     = (var.github_repo == "") == (var.github_repo_id == "")
    error_message = "Set github_repo, github_owner_id and github_repo_id together (gh api repos/OWNER/REPO --jq '.owner.id, .id')."
  }
}

variable "certificate_arn" {
  description = "Bring-your-own ACM certificate ARN (must be issued in the same region). Empty means: create and validate one when domain_name is set, otherwise HTTP only."
  type        = string
  default     = ""

  validation {
    condition     = var.certificate_arn == "" || can(regex("^arn:aws:acm:[a-z0-9-]+:[0-9]{12}:certificate/.+$", var.certificate_arn))
    error_message = "certificate_arn must be empty or a valid ACM certificate ARN."
  }
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

# --- Production settings (issue #714): every default is today's staging value. ---

variable "create_hosted_zone" {
  description = "Create hosted_zone_name as a new Route 53 zone in this account instead of looking it up. Production sets true (api.osratech.com is delegated from the management account's osratech.com zone)."
  type        = bool
  default     = false

  validation {
    condition     = !var.create_hosted_zone || var.hosted_zone_name != ""
    error_message = "create_hosted_zone needs hosted_zone_name (the zone to create, e.g. api.osratech.com)."
  }
}

variable "log_retention_days" {
  description = "CloudWatch retention for the API log group. 14 keeps staging inside its budget; production keeps 30."
  type        = number
  default     = 14
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window. 0 lets staging rebuild base on the same names at once; production keeps 7-30 days so a mistaken delete can be undone."
  type        = number
  default     = 0

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0 or between 7 and 30 (the Secrets Manager limits)."
  }
}

variable "bedrock_eval_role_enabled" {
  description = "Create the ADR-0033 Bedrock evaluation role (needs the GitHub OIDC variables). Measuring models is a staging job; production leaves it off."
  type        = bool
  default     = true
}

variable "budget_limit_usd" {
  description = "Monthly AWS Budgets limit for this account in USD; 0 creates no budget (staging's budget is managed outside Terraform)."
  type        = number
  default     = 0
}

variable "alarm_email" {
  description = "Address that receives the budget alerts. Set it in the gitignored tfvars only; never commit an address."
  type        = string
  default     = ""
  sensitive   = true
}
