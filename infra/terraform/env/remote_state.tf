# Reads the long-lived stack's outputs. `up.sh` applies base first, so this always resolves.
# Bucket, key and role come from variables so production reads its own account's state (#714); the
# defaults are staging's values.
data "terraform_remote_state" "base" {
  backend = "s3"

  config = merge(
    {
      bucket  = var.state_bucket
      key     = var.base_state_key
      region  = var.state_region
      encrypt = true
    },
    var.assume_role_arn != "" ? { assume_role = { role_arn = var.assume_role_arn } } : {},
  )

  # A load-test env must read the load-test base (loadtest.tf), checked here so the read never happens otherwise.
  lifecycle {
    precondition {
      condition     = !var.loadtest_mode || (var.base_state_key == local.loadtest_base_state_key && var.state_bucket == local.loadtest_state_bucket)
      error_message = "loadtest_mode must read the load-test base: base_state_key = \"loadtest/base/terraform.tfstate\" in the staging state bucket (never staging's base, whose DATABASE_URL secret this env would overwrite)."
    }
  }
}
