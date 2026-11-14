# Production's protections are REQUIRED, not remembered (Fable's R3 review of #765, B1). Staging creates
# no instance of this resource, so its plan is unchanged.
resource "terraform_data" "production_guard" {
  count = var.environment == "production" ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.secret_recovery_window_days >= 7
      error_message = "production: secret_recovery_window_days must be 7 or more."
    }
    precondition {
      condition     = var.budget_limit_usd > 0 && var.alarm_email != ""
      error_message = "production: set budget_limit_usd above 0 and an alarm_email."
    }
    precondition {
      condition     = !var.bedrock_eval_role_enabled
      error_message = "production: bedrock_eval_role_enabled must be false (model measurement stays in staging)."
    }
    precondition {
      condition     = var.internal_hmac_secret_enabled
      error_message = "production: internal_hmac_secret_enabled must be true (a fresh service credential)."
    }
    precondition {
      condition     = var.domain_name != "" && var.hosted_zone_name != ""
      error_message = "production: domain_name and hosted_zone_name are required (HTTPS only)."
    }
    precondition {
      condition     = startswith(var.region, "eu-")
      error_message = "production: region must be an EU region (ADR-0030: eu-central-1)."
    }
    precondition {
      condition     = length(var.allowed_account_ids) == 1 && var.assume_role_arn != ""
      error_message = "production: pin exactly one account in allowed_account_ids and set assume_role_arn."
    }
    precondition {
      condition     = var.guardduty_enabled
      error_message = "production: guardduty_enabled must be true (#766 item 2)."
    }
    precondition {
      condition     = var.secrets_out_of_band
      error_message = "production: secrets_out_of_band must be true (no secret values in Terraform state, #766 item 1)."
    }
    precondition {
      condition     = var.log_retention_days == 90
      error_message = "production: log_retention_days must be exactly 90 (#766 item 11: at least 90 for investigations; the privacy policy promises at most 90)."
    }
    precondition {
      condition     = var.alarm_email_secondary != "" && var.alarm_email_secondary != var.alarm_email
      error_message = "production: alarm_email_secondary must be set and differ from alarm_email (#766 item 6)."
    }
    precondition {
      condition     = aws_ecr_repository.api.image_tag_mutability == "IMMUTABLE" && aws_ecr_repository.api.image_scanning_configuration[0].scan_on_push
      error_message = "production: the API image repository must have immutable tags and scan-on-push (#766 item 12)."
    }
  }
}
