# Production's protections are REQUIRED, not remembered (Fable's R3 review of #765, B1). Every setting
# defaults to staging's value, so a production.tfvars that left a line out would otherwise create production
# without backups or protection and nothing would fail. With environment = "production", each rule below
# fails the plan instead. Staging creates no instance of this resource, so its plan is unchanged.
resource "terraform_data" "production_guard" {
  count = var.environment == "production" ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.db_multi_az
      error_message = "production: db_multi_az must be true."
    }
    precondition {
      condition     = var.db_backup_retention_days >= 7
      error_message = "production: db_backup_retention_days must be 7 or more."
    }
    precondition {
      condition     = var.db_deletion_protection
      error_message = "production: db_deletion_protection must be true."
    }
    precondition {
      condition     = !var.db_skip_final_snapshot
      error_message = "production: db_skip_final_snapshot must be false."
    }
    precondition {
      condition     = var.redis_transit_encryption && var.redis_failover
      error_message = "production: redis_transit_encryption and redis_failover must be true."
    }
    precondition {
      condition     = var.nat_gateway_count == 2
      error_message = "production: nat_gateway_count must be 2."
    }
    precondition {
      condition     = var.waf_enabled
      error_message = "production: waf_enabled must be true."
    }
    precondition {
      condition     = var.alarms_enabled && var.alarm_email != ""
      error_message = "production: alarms_enabled must be true with an alarm_email."
    }
    precondition {
      condition     = var.alb_deletion_protection
      error_message = "production: alb_deletion_protection must be true."
    }
    precondition {
      condition     = local.https_enabled && local.dns_record_enabled
      error_message = "production: base must provide a certificate and a hosted zone (HTTPS only)."
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
      condition     = var.cors_origin != "" && !strcontains(var.cors_origin, "*")
      error_message = "production: cors_origin must name real origins (no empty value, no wildcard)."
    }
  }
}
