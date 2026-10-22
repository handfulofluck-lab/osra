# Reads the long-lived stack's outputs. `up.sh` applies base first, so this always resolves.
data "terraform_remote_state" "base" {
  backend = "s3"

  config = {
    bucket  = "osra-terraform-state-222207908538-me-central-1"
    key     = "staging/base/terraform.tfstate"
    region  = "me-central-1"
    encrypt = true
  }
}
