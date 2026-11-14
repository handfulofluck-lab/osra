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
}
