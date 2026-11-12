# Reads the long-lived stack's outputs. `up.sh` applies base first, so this always resolves.
data "terraform_remote_state" "base" {
  backend = "s3"

  config = {
    bucket  = "osra-terraform-state-222207908538-eu-north-1"
    key     = "staging/base/terraform.tfstate"
    region  = "eu-north-1"
    encrypt = true
  }
}

# The always-on email stack (email/): the SES identity and the API task role. Read only when
# email_enabled, so a session can still come up before that stack exists.
data "terraform_remote_state" "email" {
  count   = var.email_enabled ? 1 : 0
  backend = "s3"

  config = {
    bucket  = "osra-terraform-state-222207908538-eu-north-1"
    key     = "email/terraform.tfstate"
    region  = "eu-north-1"
    encrypt = true
  }
}
