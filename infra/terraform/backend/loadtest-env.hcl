# Load-test env state. Separate key from loadtest/base so a teardown of env never touches base.
bucket = "osra-terraform-state-222207908538-eu-north-1"
key    = "loadtest/env/terraform.tfstate"
region = "eu-north-1"
