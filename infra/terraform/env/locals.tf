locals {
  # Every resource name starts with this so the AWS console and bills are readable.
  name_prefix = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    ADR         = "0028"
  }

  # The certificate is base's, so this stack cannot drift from the one it was validated as.
  certificate_arn = data.terraform_remote_state.base.outputs.certificate_arn

  # Empty certificate = non-release mode: no HTTPS listener, and port 80 forwards.
  https_enabled = local.certificate_arn != ""
}
