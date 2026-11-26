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

  # The hostname and its zone are base's too: one variable, read from one place, so base and env
  # cannot disagree about the name the certificate covers (env/dns.tf, env/outputs.tf).
  domain_name    = data.terraform_remote_state.base.outputs.domain_name
  hosted_zone_id = data.terraform_remote_state.base.outputs.hosted_zone_id

  # A record only exists when base knows both the name and the zone that holds it.
  dns_record_enabled = local.domain_name != "" && local.hosted_zone_id != ""

  # Empty certificate = non-release mode: no HTTPS listener, and port 80 forwards.
  https_enabled = local.certificate_arn != ""

  # rediss:// when the cache requires TLS: ioredis enables TLS for that scheme on its own (#714).
  redis_url = format(
    "%s://%s:6379",
    var.redis_transit_encryption ? "rediss" : "redis",
    aws_elasticache_replication_group.main.primary_endpoint_address,
  )

  # Where alarms send notifications: the SNS topic in production, nowhere in staging.
  alarm_actions = var.alarms_enabled ? [aws_sns_topic.alarms[0].arn] : []
}
