resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.name_prefix}-redis"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${local.name_prefix}-redis"
  }
}

# Redis 7 parameter-group family: the Valkey engine could not be listed at the time of writing — see
# the note on the replication group below.
resource "aws_elasticache_parameter_group" "cache" {
  name        = "${local.name_prefix}-redis7"
  family      = "redis7"
  description = "OSRA staging Redis defaults"

  tags = {
    Name = "${local.name_prefix}-redis7"
  }
}

# One node, no replica. ADR-0028 names ElastiCache Valkey because the API fail-closes parent
# sessions when Redis is unreachable; a second node would double the bill for a cache that is
# rebuildable. Staging accepts the restart risk.
#
# Engine is redis 7.1, not valkey: on 2026-10-22, in me-central-1, `aws elasticache
# describe-cache-engine-versions --engine valkey` returned InternalFailure (three attempts) while
# `--engine redis` listed 6.2/7.0/7.1. The API's ioredis client speaks the same protocol.
#
# That observation is dated, and staging no longer runs in that region: it moved to eu-north-1 on
# 2026-10-22 (ADR-0030). The lookup was repeated there afterwards (Claude, read-only) and lists valkey
# 7.2, 8.0, 8.1, 8.2, 9.0 and 9.1, so this engine choice is valid in Stockholm too — the reason it is
# still `redis` is the production family, not a regional gap. Switching staging to valkey belongs in
# its own change (`engine = "valkey"`, family valkey8); it costs nothing to try because `env` is rebuilt
# every session.
# Production MUST recheck Valkey in Frankfurt (eu-central-1) before it matters (ADR-0030 decision 6
# also asks for one staging run there before go-live).
resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${local.name_prefix}-redis"
  description          = "OSRA staging cache for fan-out and revocation flags"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.redis_node_type
  num_cache_clusters   = 1
  parameter_group_name = aws_elasticache_parameter_group.cache.name
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]
  port                 = 6379

  # A single node cannot have automatic failover or Multi-AZ.
  automatic_failover_enabled = false
  multi_az_enabled           = false

  # The API's REDIS_URL is redis://, so TLS must stay off until the client is taught rediss://.
  transit_encryption_enabled = false
  at_rest_encryption_enabled = true

  apply_immediately          = true
  auto_minor_version_upgrade = true

  # No snapshots: cache contents are reconstructible and staging does not pay for backups.
  snapshot_retention_limit = 0

  tags = {
    Name = "${local.name_prefix}-redis"
  }
}
