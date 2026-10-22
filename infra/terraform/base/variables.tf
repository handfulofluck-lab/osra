variable "region" {
  description = "AWS region for this regional stack (ADR-0028: one independent stack per market)."
  type        = string
  default     = "me-central-1"
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
