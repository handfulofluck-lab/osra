# Plan-only checks with a mocked AWS provider (#714): no credentials, no state, runs in CI.
# They pin what each environment's settings turn into, so a later edit cannot quietly weaken production
# or change what staging creates.

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["zone-a", "zone-b", "zone-c"]
    }
  }

  # The provider checks ARN syntax even against a mock, so the ARNs other resources consume need a shape.
  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:eu-central-1:000000000000:loadbalancer/app/test/1"
      arn_suffix = "app/test/1"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:eu-central-1:000000000000:targetgroup/test/1"
      arn_suffix = "targetgroup/test/1"
    }
  }
  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:eu-central-1:000000000000:test-alarms"
    }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = {
      arn = "arn:aws:wafv2:eu-central-1:000000000000:regional/webacl/test/1"
    }
  }
  mock_resource "aws_ecs_cluster" {
    defaults = {
      arn = "arn:aws:ecs:eu-central-1:000000000000:cluster/test"
    }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:eu-central-1:000000000000:task-definition/test:1"
    }
  }
}

mock_provider "random" {}

override_data {
  target = data.terraform_remote_state.base
  values = {
    outputs = {
      certificate_arn                = "arn:aws:acm:eu-central-1:000000000000:certificate/test"
      domain_name                    = "api.example.test"
      hosted_zone_id                 = "ZTEST"
      execution_role_arn             = "arn:aws:iam::000000000000:role/test-execution"
      database_url_secret_arn        = "arn:aws:secretsmanager:eu-central-1:000000000000:secret:db"
      jwt_secret_arn                 = "arn:aws:secretsmanager:eu-central-1:000000000000:secret:jwt"
      vault_key_secret_arn           = "arn:aws:secretsmanager:eu-central-1:000000000000:secret:vault"
      demo_password_secret_arn       = "arn:aws:secretsmanager:eu-central-1:000000000000:secret:demo"
      fcm_service_account_secret_arn = "arn:aws:secretsmanager:eu-central-1:000000000000:secret:fcm"
      log_group_name                 = "/ecs/test-api"
      internal_hmac_secret_arn       = "arn:aws:secretsmanager:eu-central-1:000000000000:secret:hmac"
    }
  }
}

override_resource {
  target = aws_elasticache_replication_group.main
  values = {
    primary_endpoint_address = "cache.example.internal"
  }
}

# `apply` here applies to the MOCK provider only: nothing reaches AWS. It makes computed values known.
run "staging_defaults_are_unchanged" {
  command = apply

  variables {
    api_image = "example/api:test"
  }

  assert {
    condition     = length(aws_nat_gateway.main) == 1 && length(aws_route_table.private) == 1
    error_message = "staging must keep one NAT gateway and one private route table"
  }
  assert {
    condition     = aws_db_instance.main.multi_az == false && aws_db_instance.main.backup_retention_period == 0 && aws_db_instance.main.deletion_protection == false && aws_db_instance.main.skip_final_snapshot == true
    error_message = "staging database settings changed"
  }
  assert {
    condition     = aws_db_instance.main.allocated_storage == 20 && aws_db_instance.main.instance_class == "db.t4g.micro"
    error_message = "staging database size changed"
  }
  assert {
    condition     = aws_elasticache_replication_group.main.num_cache_clusters == 1 && aws_elasticache_replication_group.main.transit_encryption_enabled == false
    error_message = "staging cache changed"
  }
  assert {
    condition     = local.redis_url == "redis://cache.example.internal:6379"
    error_message = "staging must keep a plain redis:// URL"
  }
  assert {
    condition     = length(aws_wafv2_web_acl.api) == 0 && length(aws_sns_topic.alarms) == 0 && length(aws_cloudwatch_metric_alarm.this) == 0
    error_message = "staging must not create WAF, alarm topic or the production alarms"
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.redis_memory) == 1 && aws_cloudwatch_metric_alarm.redis_memory[0].alarm_name == "osra-staging-redis-memory-70"
    error_message = "staging's Redis memory alarm must keep its name"
  }
  assert {
    condition     = aws_appautoscaling_target.ecs[0].min_capacity == 2 && aws_appautoscaling_target.ecs[0].max_capacity == 4
    error_message = "staging autoscaling changed"
  }
  assert {
    condition     = aws_lb.main.enable_deletion_protection == false
    error_message = "staging ALB must stay deletable by down.sh"
  }
}

run "production_settings" {
  command = apply

  variables {
    environment              = "production"
    region                   = "eu-central-1"
    api_image                = "example/api:test"
    api_cpu                  = 1024
    api_memory               = 2048
    api_min_count            = 2
    api_max_count            = 6
    nat_gateway_count        = 2
    db_instance_class        = "db.t4g.small"
    db_multi_az              = true
    db_allocated_storage     = 50
    db_max_allocated_storage = 200
    db_backup_retention_days = 14
    db_deletion_protection   = true
    db_skip_final_snapshot   = false
    db_performance_insights  = true
    redis_num_nodes          = 2
    redis_failover           = true
    redis_transit_encryption = true
    alb_deletion_protection  = true
    waf_enabled              = true
    alarms_enabled           = true
    alarm_email              = "alerts@example.test"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  assert {
    condition     = length(aws_nat_gateway.main) == 2 && aws_route_table_association.private[1].route_table_id == aws_route_table.private[1].id
    error_message = "production needs one NAT gateway and route table per AZ"
  }
  assert {
    condition     = aws_db_instance.main.multi_az && aws_db_instance.main.backup_retention_period == 14 && aws_db_instance.main.deletion_protection && !aws_db_instance.main.skip_final_snapshot
    error_message = "production database must be Multi-AZ, backed up 14 days, protected, with a final snapshot"
  }
  assert {
    condition     = aws_db_instance.main.final_snapshot_identifier == "osra-production-postgres-final" && aws_db_instance.main.storage_encrypted
    error_message = "production final snapshot name or encryption wrong"
  }
  assert {
    condition     = aws_db_instance.main.apply_immediately == false
    error_message = "production database changes must wait for the maintenance window"
  }
  assert {
    condition     = aws_elasticache_replication_group.main.num_cache_clusters == 2 && aws_elasticache_replication_group.main.automatic_failover_enabled && aws_elasticache_replication_group.main.transit_encryption_enabled
    error_message = "production cache must have a replica, failover and TLS"
  }
  assert {
    condition     = local.redis_url == "rediss://cache.example.internal:6379"
    error_message = "production must hand the API a rediss:// URL"
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.redis_memory) == 2 && length(aws_cloudwatch_metric_alarm.this) == 8
    error_message = "production needs a memory alarm per cache node and the eight service alarms"
  }
  assert {
    condition     = length(aws_wafv2_web_acl_association.api) == 1 && length(aws_sns_topic_subscription.alarms_email) == 1
    error_message = "production needs the WAF on the ALB and the alarm e-mail subscription"
  }
  assert {
    condition     = aws_appautoscaling_target.ecs[0].min_capacity == 2 && aws_appautoscaling_target.ecs[0].max_capacity == 6
    error_message = "production autoscaling must be 2-6"
  }
  assert {
    condition     = aws_lb_listener.https[0].ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06" && aws_lb_listener.http.default_action[0].type == "redirect"
    error_message = "production must keep TLS 1.2+/1.3 and the HTTP->HTTPS redirect"
  }
  assert {
    condition     = aws_lb.main.enable_deletion_protection
    error_message = "production ALB must be protected"
  }
  assert {
    condition     = contains([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].secrets : x.name], "INTERNAL_HMAC_SECRET") && !contains([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : x.name], "INTERNAL_HMAC_SECRET")
    error_message = "INTERNAL_HMAC_SECRET must reach the task as a secrets entry, never an environment variable"
  }
  assert {
    condition     = !strcontains(aws_ecs_task_definition.api.container_definitions, "IDLE_BUDGET_COUNTING")
    error_message = "production must not carry the staging-only idle-budget counter (#346)"
  }
  assert {
    condition     = !strcontains(aws_ecs_task_definition.api.container_definitions, "SEED_DEMO_PASSWORD")
    error_message = "production tasks must not receive the demo password"
  }
}

run "failover_needs_two_nodes" {
  command = plan

  variables {
    api_image       = "example/api:test"
    redis_failover  = true
    redis_num_nodes = 1
  }

  expect_failures = [var.redis_failover]
}

# B1: production without any one protection fails to plan.

run "production_requires_db_multi_az" {
  command = plan

  variables {
    environment              = "production"
    region                   = "eu-central-1"
    api_image                = "example/api:test"
    api_cpu                  = 1024
    api_memory               = 2048
    api_min_count            = 2
    api_max_count            = 6
    nat_gateway_count        = 2
    db_instance_class        = "db.t4g.small"
    db_multi_az              = false
    db_allocated_storage     = 50
    db_max_allocated_storage = 200
    db_backup_retention_days = 14
    db_deletion_protection   = true
    db_skip_final_snapshot   = false
    db_performance_insights  = true
    redis_num_nodes          = 2
    redis_failover           = true
    redis_transit_encryption = true
    alb_deletion_protection  = true
    waf_enabled              = true
    alarms_enabled           = true
    alarm_email              = "alerts@example.test"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_db_backup_retention_days" {
  command = plan

  variables {
    environment              = "production"
    region                   = "eu-central-1"
    api_image                = "example/api:test"
    api_cpu                  = 1024
    api_memory               = 2048
    api_min_count            = 2
    api_max_count            = 6
    nat_gateway_count        = 2
    db_instance_class        = "db.t4g.small"
    db_multi_az              = true
    db_allocated_storage     = 50
    db_max_allocated_storage = 200
    db_backup_retention_days = 0
    db_deletion_protection   = true
    db_skip_final_snapshot   = false
    db_performance_insights  = true
    redis_num_nodes          = 2
    redis_failover           = true
    redis_transit_encryption = true
    alb_deletion_protection  = true
    waf_enabled              = true
    alarms_enabled           = true
    alarm_email              = "alerts@example.test"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_db_deletion_protection" {
  command = plan

  variables {
    environment              = "production"
    region                   = "eu-central-1"
    api_image                = "example/api:test"
    api_cpu                  = 1024
    api_memory               = 2048
    api_min_count            = 2
    api_max_count            = 6
    nat_gateway_count        = 2
    db_instance_class        = "db.t4g.small"
    db_multi_az              = true
    db_allocated_storage     = 50
    db_max_allocated_storage = 200
    db_backup_retention_days = 14
    db_deletion_protection   = false
    db_skip_final_snapshot   = false
    db_performance_insights  = true
    redis_num_nodes          = 2
    redis_failover           = true
    redis_transit_encryption = true
    alb_deletion_protection  = true
    waf_enabled              = true
    alarms_enabled           = true
    alarm_email              = "alerts@example.test"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_db_skip_final_snapshot" {
  command = plan

  variables {
    environment              = "production"
    region                   = "eu-central-1"
    api_image                = "example/api:test"
    api_cpu                  = 1024
    api_memory               = 2048
    api_min_count            = 2
    api_max_count            = 6
    nat_gateway_count        = 2
    db_instance_class        = "db.t4g.small"
    db_multi_az              = true
    db_allocated_storage     = 50
    db_max_allocated_storage = 200
    db_backup_retention_days = 14
    db_deletion_protection   = true
    db_skip_final_snapshot   = true
    db_performance_insights  = true
    redis_num_nodes          = 2
    redis_failover           = true
    redis_transit_encryption = true
    alb_deletion_protection  = true
    waf_enabled              = true
    alarms_enabled           = true
    alarm_email              = "alerts@example.test"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_redis_transit_encryption" {
  command = plan

  variables {
    environment              = "production"
    region                   = "eu-central-1"
    api_image                = "example/api:test"
    api_cpu                  = 1024
    api_memory               = 2048
    api_min_count            = 2
    api_max_count            = 6
    nat_gateway_count        = 2
    db_instance_class        = "db.t4g.small"
    db_multi_az              = true
    db_allocated_storage     = 50
    db_max_allocated_storage = 200
    db_backup_retention_days = 14
    db_deletion_protection   = true
    db_skip_final_snapshot   = false
    db_performance_insights  = true
    redis_num_nodes          = 2
    redis_failover           = true
    redis_transit_encryption = false
    alb_deletion_protection  = true
    waf_enabled              = true
    alarms_enabled           = true
    alarm_email              = "alerts@example.test"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_nat_gateway_count" {
  command = plan

  variables {
    environment              = "production"
    region                   = "eu-central-1"
    api_image                = "example/api:test"
    api_cpu                  = 1024
    api_memory               = 2048
    api_min_count            = 2
    api_max_count            = 6
    nat_gateway_count        = 1
    db_instance_class        = "db.t4g.small"
    db_multi_az              = true
    db_allocated_storage     = 50
    db_max_allocated_storage = 200
    db_backup_retention_days = 14
    db_deletion_protection   = true
    db_skip_final_snapshot   = false
    db_performance_insights  = true
    redis_num_nodes          = 2
    redis_failover           = true
    redis_transit_encryption = true
    alb_deletion_protection  = true
    waf_enabled              = true
    alarms_enabled           = true
    alarm_email              = "alerts@example.test"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_waf_enabled" {
  command = plan

  variables {
    environment              = "production"
    region                   = "eu-central-1"
    api_image                = "example/api:test"
    api_cpu                  = 1024
    api_memory               = 2048
    api_min_count            = 2
    api_max_count            = 6
    nat_gateway_count        = 2
    db_instance_class        = "db.t4g.small"
    db_multi_az              = true
    db_allocated_storage     = 50
    db_max_allocated_storage = 200
    db_backup_retention_days = 14
    db_deletion_protection   = true
    db_skip_final_snapshot   = false
    db_performance_insights  = true
    redis_num_nodes          = 2
    redis_failover           = true
    redis_transit_encryption = true
    alb_deletion_protection  = true
    waf_enabled              = false
    alarms_enabled           = true
    alarm_email              = "alerts@example.test"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_alarms_enabled" {
  command = plan

  variables {
    environment              = "production"
    region                   = "eu-central-1"
    api_image                = "example/api:test"
    api_cpu                  = 1024
    api_memory               = 2048
    api_min_count            = 2
    api_max_count            = 6
    nat_gateway_count        = 2
    db_instance_class        = "db.t4g.small"
    db_multi_az              = true
    db_allocated_storage     = 50
    db_max_allocated_storage = 200
    db_backup_retention_days = 14
    db_deletion_protection   = true
    db_skip_final_snapshot   = false
    db_performance_insights  = true
    redis_num_nodes          = 2
    redis_failover           = true
    redis_transit_encryption = true
    alb_deletion_protection  = true
    waf_enabled              = true
    alarms_enabled           = false
    alarm_email              = "alerts@example.test"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_alb_deletion_protection" {
  command = plan

  variables {
    environment              = "production"
    region                   = "eu-central-1"
    api_image                = "example/api:test"
    api_cpu                  = 1024
    api_memory               = 2048
    api_min_count            = 2
    api_max_count            = 6
    nat_gateway_count        = 2
    db_instance_class        = "db.t4g.small"
    db_multi_az              = true
    db_allocated_storage     = 50
    db_max_allocated_storage = 200
    db_backup_retention_days = 14
    db_deletion_protection   = true
    db_skip_final_snapshot   = false
    db_performance_insights  = true
    redis_num_nodes          = 2
    redis_failover           = true
    redis_transit_encryption = true
    alb_deletion_protection  = false
    waf_enabled              = true
    alarms_enabled           = true
    alarm_email              = "alerts@example.test"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_region" {
  command = plan

  variables {
    environment              = "production"
    region                   = "us-east-1"
    api_image                = "example/api:test"
    api_cpu                  = 1024
    api_memory               = 2048
    api_min_count            = 2
    api_max_count            = 6
    nat_gateway_count        = 2
    db_instance_class        = "db.t4g.small"
    db_multi_az              = true
    db_allocated_storage     = 50
    db_max_allocated_storage = 200
    db_backup_retention_days = 14
    db_deletion_protection   = true
    db_skip_final_snapshot   = false
    db_performance_insights  = true
    redis_num_nodes          = 2
    redis_failover           = true
    redis_transit_encryption = true
    alb_deletion_protection  = true
    waf_enabled              = true
    alarms_enabled           = true
    alarm_email              = "alerts@example.test"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_assume_role_arn" {
  command = plan

  variables {
    environment              = "production"
    region                   = "eu-central-1"
    api_image                = "example/api:test"
    api_cpu                  = 1024
    api_memory               = 2048
    api_min_count            = 2
    api_max_count            = 6
    nat_gateway_count        = 2
    db_instance_class        = "db.t4g.small"
    db_multi_az              = true
    db_allocated_storage     = 50
    db_max_allocated_storage = 200
    db_backup_retention_days = 14
    db_deletion_protection   = true
    db_skip_final_snapshot   = false
    db_performance_insights  = true
    redis_num_nodes          = 2
    redis_failover           = true
    redis_transit_encryption = true
    alb_deletion_protection  = true
    waf_enabled              = true
    alarms_enabled           = true
    alarm_email              = "alerts@example.test"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = ""
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_cors_origin" {
  command = plan

  variables {
    environment              = "production"
    region                   = "eu-central-1"
    api_image                = "example/api:test"
    api_cpu                  = 1024
    api_memory               = 2048
    api_min_count            = 2
    api_max_count            = 6
    nat_gateway_count        = 2
    db_instance_class        = "db.t4g.small"
    db_multi_az              = true
    db_allocated_storage     = 50
    db_max_allocated_storage = 200
    db_backup_retention_days = 14
    db_deletion_protection   = true
    db_skip_final_snapshot   = false
    db_performance_insights  = true
    redis_num_nodes          = 2
    redis_failover           = true
    redis_transit_encryption = true
    alb_deletion_protection  = true
    waf_enabled              = true
    alarms_enabled           = true
    alarm_email              = "alerts@example.test"
    cors_origin              = ""
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}
