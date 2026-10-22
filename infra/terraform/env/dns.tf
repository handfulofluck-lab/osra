# Every `up` creates an ALB with a new DNS name, so without this record `api_url` prints a hostname
# that resolves to nothing; the alias is per-session because the ALB it points at is.
resource "aws_route53_record" "api" {
  count = local.dns_record_enabled ? 1 : 0

  zone_id = local.hosted_zone_id
  name    = local.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = false # an alias health check would only duplicate the target group's
  }
}
