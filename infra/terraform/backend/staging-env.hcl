# Staging per-session state. Same bucket as base, separate key so `down` never touches base's state.
bucket = "osra-terraform-state-222207908538-eu-north-1"
key    = "staging/env/terraform.tfstate"
region = "eu-north-1"
