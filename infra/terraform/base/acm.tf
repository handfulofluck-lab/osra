# The certificate is created once because re-validating DNS on every `up` would add minutes and a
# failure mode to a routine step; the ALB that uses it is per-session and lives in env.

resource "aws_acm_certificate" "api" {
  count = local.create_certificate ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  # A replacement certificate must exist before the old one is removed.
  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${local.name_prefix}-api"
  }
}

data "aws_route53_zone" "main" {
  count = local.create_certificate ? 1 : 0

  name         = var.hosted_zone_name
  private_zone = false
}

resource "aws_route53_record" "validation" {
  for_each = local.create_certificate ? {
    for dvo in aws_acm_certificate.api[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  } : {}

  zone_id         = data.aws_route53_zone.main[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Waiting here means env never creates an HTTPS listener against an unvalidated certificate.
resource "aws_acm_certificate_validation" "api" {
  count = local.create_certificate ? 1 : 0

  certificate_arn         = aws_acm_certificate.api[0].arn
  validation_record_fqdns = [for record in aws_route53_record.validation : record.fqdn]
}
