# Load-test base state (loadtest/README.md). Same staging bucket, its own key: the load-test stack never reads or
# writes staging's state, and staging's `down.sh`/`up.sh` never see this one.
bucket = "osra-terraform-state-222207908538-eu-north-1"
key    = "loadtest/base/terraform.tfstate"
region = "eu-north-1"
