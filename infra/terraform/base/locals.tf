locals {
  # Every resource name starts with this so the AWS console and bills are readable.
  name_prefix = "${var.project}-${var.environment}"

  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    ADR         = "0028"
  }

  # A domain with no supplied ARN means this stack owns the certificate and its DNS validation.
  create_certificate = var.domain_name != "" && var.certificate_arn == ""

  # The effective ARN env reads. A supplied ARN wins; otherwise the one created here, or empty.
  certificate_arn = var.certificate_arn != "" ? var.certificate_arn : (
    local.create_certificate ? aws_acm_certificate.api[0].arn : ""
  )
}
