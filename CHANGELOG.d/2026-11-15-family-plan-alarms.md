### Infrastructure — alarms when a family's plan is dropped from entitlement (#811)
- `infra/terraform/env/family_plan_alarms.tf`: CloudWatch Logs metric filters on the API log group for the
  one-line JSON warnings `family_plan_recovery_ceiling` (a grace/on-hold store purchase passed the lost-push
  ceiling) and `family_plan_missing_expiry` (a purchase row with no expiry). Each feeds an alarm to the
  environment's alarm topic on the first occurrence, so a paying family losing access is seen the same day.
