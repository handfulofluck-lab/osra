# Staging base state (eu-north-1 since 2026-10-22, ADR-0030). Values unchanged from the inline backend
# block they replaced in #714; up.sh passes this file with `init -reconfigure`.
bucket = "osra-terraform-state-222207908538-eu-north-1"
key    = "staging/base/terraform.tfstate"
region = "eu-north-1"
