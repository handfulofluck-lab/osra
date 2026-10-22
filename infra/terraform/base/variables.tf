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

variable "certificate_arn" {
  description = "Bring-your-own ACM certificate ARN (must be issued in the same region). Empty means: create and validate one when domain_name is set, otherwise HTTP only."
  type        = string
  default     = ""

  validation {
    condition     = var.certificate_arn == "" || can(regex("^arn:aws:acm:[a-z0-9-]+:[0-9]{12}:certificate/.+$", var.certificate_arn))
    error_message = "certificate_arn must be empty or a valid ACM certificate ARN."
  }
}
