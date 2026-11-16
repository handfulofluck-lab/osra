variable "region" {
  description = "Region of the training bucket and jobs. Production data stays in Frankfurt (ADR-0030)."
  type        = string
  default     = "eu-central-1"
}

variable "assume_role_arn" {
  description = "Role the provider assumes inside osra-production (same deploy role as env). Empty only when the profile is already in that account."
  type        = string
  default     = ""

  validation {
    condition     = var.assume_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.assume_role_arn))
    error_message = "assume_role_arn must be empty or an IAM role ARN."
  }
}

variable "allowed_account_ids" {
  description = "The one account this stack may touch. Required: there is no unpinned mode."
  type        = list(string)

  validation {
    condition     = length(var.allowed_account_ids) == 1
    error_message = "Pin exactly one account ID."
  }
}

variable "operator_role_arns" {
  description = "Roles allowed to reach the bucket besides the training role: the deploy role (Terraform) and the role that uploads training files and starts the job. Every other principal is denied by the bucket policy. Give IAM role ARNs (arn:aws:iam::<account>:role/<name>), never assumed-role session ARNs, and always include the role Terraform itself runs as, or the next refresh is denied and only the account root can remove the policy."
  type        = list(string)

  validation {
    condition     = length(var.operator_role_arns) > 0 && alltrue([for a in var.operator_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", a))])
    error_message = "Give at least one IAM role ARN."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary for the training role. Null = none. Set it if the security review asks for one; the inline policy is the limit either way."
  type        = string
  default     = null
}

variable "training_image_repository_arns" {
  description = "ECR repositories the job may pull its image from. Default: the AWS Deep Learning Containers registry in this region."
  type        = list(string)
  default     = ["arn:aws:ecr:eu-central-1:763104351884:repository/*"]
}

variable "expire_after_days" {
  description = "Objects (training text, checkpoints, model output) are deleted this many days after upload. Download a model you want to keep."
  type        = number
  default     = 30

  validation {
    condition     = var.expire_after_days >= 1 && var.expire_after_days <= 365
    error_message = "expire_after_days must be between 1 and 365."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget for resources tagged Purpose=ml-training. An alert, not a cap: the cap is each job's MaxRuntimeInSeconds."
  type        = number
  default     = 100
}

variable "budget_alert_emails" {
  description = "Who is emailed at 80% actual and 100% forecast of the budget. Required: a budget with nobody to tell is not an alert."
  type        = list(string)

  validation {
    condition     = length(var.budget_alert_emails) > 0 && alltrue([for e in var.budget_alert_emails : can(regex("^[^@ ]+@[^@ ]+[.][^@ ]+$", e))])
    error_message = "Give at least one email address for the budget alert."
  }
}
