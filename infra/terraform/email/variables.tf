variable "region" {
  description = "Region of the SES identity. It must match the region the API task runs in (staging: eu-north-1)."
  type        = string
  default     = "eu-north-1"
}

variable "environment" {
  description = "Names the API task role (osra-<environment>-api-task)."
  type        = string
  default     = "staging"
}

variable "domain" {
  description = "The sending domain. Its Route 53 zone must already exist in this account."
  type        = string
  default     = "osratech.com"
}
