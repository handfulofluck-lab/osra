resource "aws_elasticache_subnet_group" "main" {
  name       = "${local.name_prefix}-redis"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${local.name_prefix}-redis"
  }
}

# Redis 7 parameter-group family: the Valkey engine could not be listed at the time of writing — see
# the note on the replication group below.
#
# `maxmemory-policy = noeviction` is a security setting, not a tuning knob (ADR-0032). The default
# `allkeys-lru` lets Redis silently delete the keys that carry revocation state —
# `auth:session-version:<parentId>`, `revoked:token:<jti>`, `revoked:device:<deviceId>` — under memory
# pressure, and an evicted key reads as "nothing was revoked". Since the API now stores every
# revocation in Postgres and treats these keys as a cache, an eviction costs a database read rather
# than a resurrection; noeviction turns a full node into write errors the API fails closed on instead
# of a silent data loss whose only symptom is a revoked session that works again.
resource "aws_elasticache_parameter_group" "cache" {
  name        = "${local.name_prefix}-redis7"
  family      = "redis7"
  description = "OSRA ${var.environment} Redis defaults"

  parameter {
    name  = "maxmemory-policy"
    value = "noeviction"
  }

  tags = {
    Name = "${local.name_prefix}-redis7"
  }
}

# Staging: one node, no replica. Production (#714): a primary and a replica in the other AZ with
# automatic failover, and TLS in transit. ADR-0028 names ElastiCache Valkey because the API fail-closes parent
# sessions when Redis is unreachable; a second node would double the bill for a cache whose bulk is
# rebuildable — the revocation keys are rebuilt from Postgres, not from another node (ADR-0032).
# Staging accepts the restart risk.
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
  description          = "OSRA ${var.environment} cache for fan-out and revocation flags"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.redis_node_type
  num_cache_clusters   = var.redis_num_nodes
  parameter_group_name = aws_elasticache_parameter_group.cache.name
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]
  port                 = 6379

  # A single node cannot have automatic failover or Multi-AZ (the variable's validation enforces it).
  automatic_failover_enabled = var.redis_failover
  multi_az_enabled           = var.redis_failover

  # With TLS on, ecs.tf hands the API a rediss:// URL; ioredis turns TLS on for that scheme by itself
  # (test: services/api/test/redis-url-tls.test.ts). Changing this replaces the group (#714).
  transit_encryption_enabled = var.redis_transit_encryption
  at_rest_encryption_enabled = true

  apply_immediately          = var.environment != "production"
  auto_minor_version_upgrade = true

  # One daily snapshot (ADR-0032). The rest of the keyspace is reconstructible — pub/sub fan-out,
  # usage counters, refresh records — but the revocation keys are not: `auth:session-version:<parentId>`
  # (a monotonic counter, whose loss reads as "nothing was revoked"), `revoked:token:<jti>` (the
  # single-logout record, mirrored in the RevokedToken table) and `revoked:device:<deviceId>` (what
  # makes an unpaired phone's 10-year token answer 401). Postgres is the record for all three and the
  # API rebuilds each key on a miss, so the snapshot is a second line of defence, not the mechanism:
  # it bounds the window in which a restart plus a missing Postgres row could resurrect a session.
  snapshot_retention_limit = 1

  tags = {
    Name = "${local.name_prefix}-redis"
  }

  # Production's AUTH token is set by production-secrets.sh (modify-replication-group --auth-token), so the
  # token never enters state (#766 item 3). Terraform must not try to undo it.
  lifecycle {
    ignore_changes = [auth_token, auth_token_update_strategy]
  }
}

# The rate limiter keeps its counters here under `rl:` (each expires with its one-minute window), so
# a flood from many addresses grows the keyspace. Under `noeviction` a full node turns writes into
# errors, revocation writes included, so warn well before that. One alarm per node, because either may
# be the primary after a failover. Staging has no alerting topic, so its alarm shows only in the
# console; production sends it to the SNS topic in alarms.tf.
resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  count = var.redis_num_nodes

  alarm_name          = count.index == 0 ? "${local.name_prefix}-redis-memory-70" : "${local.name_prefix}-redis-memory-70-${format("%03d", count.index + 1)}"
  alarm_description   = "Redis memory above 70% (noeviction: a full node refuses writes, revocations included)."
  namespace           = "AWS/ElastiCache"
  metric_name         = "DatabaseMemoryUsagePercentage"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 70
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    CacheClusterId = "${aws_elasticache_replication_group.main.replication_group_id}-${format("%03d", count.index + 1)}"
  }

  tags = {
    Name = count.index == 0 ? "${local.name_prefix}-redis-memory-70" : "${local.name_prefix}-redis-memory-70-${format("%03d", count.index + 1)}"
  }
}

moved {
  from = aws_cloudwatch_metric_alarm.redis_memory
  to   = aws_cloudwatch_metric_alarm.redis_memory[0]
}
