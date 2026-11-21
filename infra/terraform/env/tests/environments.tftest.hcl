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
  mock_resource "aws_s3_bucket" {
    defaults = {
      arn = "arn:aws:s3:::test-access-logs"
      id  = "test-access-logs"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:eu-central-1:000000000000:log-group:test"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:eu-central-1:000000000000:key/test"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      arn = "arn:aws:rds:eu-central-1:000000000000:db:test"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::000000000000:role/test"
    }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:eu-central-1:000000000000:task-definition/test:1"
    }
  }
}

mock_provider "random" {}

# Every run gets the e-mail settings production requires (#781 review); runs override what they test.
variables {
  app_public_url = "https://app.example.test"
  email_provider = "ses"
  email_from     = "OSRA <no-reply@example.test>"
}

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
      apns_key_p8_secret_arn         = "arn:aws:secretsmanager:eu-central-1:000000000000:secret:apns"
      log_group_name                 = "/ecs/test-api"
      internal_hmac_secret_arn       = "arn:aws:secretsmanager:eu-central-1:000000000000:secret:hmac"
      execution_role_name            = "test-execution"
      api_db_password_secret_arn     = "arn:aws:secretsmanager:eu-central-1:000000000000:secret:apidb"
      redis_url_secret_arn           = "arn:aws:secretsmanager:eu-central-1:000000000000:secret:redisurl"
    }
  }
}

override_resource {
  target = aws_db_instance.main
  values = {
    address = "db.example.internal"
    master_user_secret = [{
      secret_arn    = "arn:aws:secretsmanager:eu-central-1:000000000000:secret:rds-master"
      kms_key_id    = ""
      secret_status = "active"
    }]
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
    condition     = length(aws_vpc_endpoint.staging_qa_bedrock) == 0 && length(aws_ecs_service.staging_qa_analyzer) == 0 && !contains([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : x.name], "OSRA_STAGING_QA_ANALYZER_ENABLED")
    error_message = "staging QA creates no endpoint, service or API gate unless explicitly requested"
  }

  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.family_plan) == 0 && length(aws_cloudwatch_metric_alarm.family_plan) == 0
    error_message = "with alarms_enabled false there are no family plan filters or alarms (#816)"
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
  assert {
    condition     = length(random_password.db) == 1 && length(aws_ecs_task_definition.db_admin) == 0 && contains([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : x.name], "REDIS_URL")
    error_message = "staging keeps Terraform-generated secrets and a plain REDIS_URL"
  }
  assert {
    condition     = length([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : x.name if startswith(x.name, "APNS_")]) == 0 && !contains([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].secrets : x.name], "APNS_KEY_P8")
    error_message = "with apns_enabled false the task carries no APNs setting (#695)"
  }
  assert {
    condition     = length(aws_flow_log.vpc) == 0 && length(aws_s3_bucket.access_logs) == 0 && length(aws_lb.main.access_logs) == 0
    error_message = "staging creates no audit logs"
  }
  assert {
    condition     = one([for p in aws_db_parameter_group.postgres.parameter : p.value if p.name == "rds.force_ssl"]) == "1" && aws_db_instance.main.parameter_group_name == aws_db_parameter_group.postgres.name
    error_message = "the database must require TLS through its own parameter group (#766 item 9)"
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.api_https.from_port == 443 && aws_vpc_security_group_egress_rule.api_https.to_port == 443 && aws_vpc_security_group_egress_rule.api_to_rds.from_port == 5432 && aws_vpc_security_group_egress_rule.api_to_redis.from_port == 6379
    error_message = "API tasks may leave only on 443, plus PostgreSQL and Redis inside the VPC (#766 item 6)"
  }
}

run "armed_qa_analyzer_plans_only_the_private_scoped_route" {
  command = plan

  variables {
    api_image           = "example/api:test"
    allowed_account_ids = [format("%012d", 0)]
    staging_qa_analyzer = {
      armed               = true
      image_digest        = "sha256:${sha256("qa-image")}"
      frankfurt_vpc_cidr  = format("%d.%d.%d.%d/%d", 10, 40, 0, 0, 24)
      prompt_secret_arn   = format("arn:aws:secretsmanager:eu-north-1:%012d:secret:test-prompt", 0)
      approval_secret_arn = format("arn:aws:secretsmanager:eu-north-1:%012d:secret:test-approval", 0)
      pairing_secret_arn  = format("arn:aws:secretsmanager:eu-north-1:%012d:secret:test-pairing", 0)
    }
  }

  override_resource {
    target          = aws_vpc_endpoint.staging_qa_bedrock[0]
    override_during = plan

    values = {
      id = "vpce-test"
      dns_entry = [{
        dns_name       = "vpce-0123456789abcdef0-osratest.bedrock-runtime.eu-central-1.vpce.amazonaws.com"
        hosted_zone_id = "ZTEST"
      }]
    }
  }

  override_resource {
    target          = aws_iam_role.staging_qa_analyzer_task[0]
    override_during = plan

    values = {
      arn = "arn:aws:iam::000000000000:role/test-analyzer-task"
    }
  }

  assert {
    condition     = aws_vpc_endpoint.staging_qa_bedrock[0].region == "eu-central-1" && aws_vpc_endpoint.staging_qa_bedrock[0].vpc_endpoint_type == "Interface" && !aws_vpc_endpoint.staging_qa_bedrock[0].private_dns_enabled && !one(aws_ecs_service.staging_qa_analyzer[0].network_configuration).assign_public_ip
    error_message = "the service stays private and the model endpoint remains in Frankfurt"
  }

  # Omitting the explicit URL or substituting the public endpoint leaves this assertion red.
  assert {
    condition = alltrue([
      one([
        for item in jsondecode(aws_ecs_task_definition.staging_qa_analyzer[0].container_definitions)[0].environment
        : item.value if item.name == "OSRA_STAGING_QA_BEDROCK_ENDPOINT_URL"
      ]) == "https://${aws_vpc_endpoint.staging_qa_bedrock[0].dns_entry[0].dns_name}",
      !contains([
        for item in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : item.name
      ], "OSRA_STAGING_QA_BEDROCK_ENDPOINT_URL"),
    ])
    error_message = "only the armed analyzer receives the Frankfurt endpoint's regional URL"
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.staging_qa_analyzer_task[0].policy).Statement == [{
      Effect   = "Allow"
      Action   = "bedrock:InvokeModel"
      Resource = "arn:aws:bedrock:eu-central-1::foundation-model/openai.gpt-oss-20b-1:0"
      Condition = {
        StringEquals = {
          "aws:RequestedRegion" = "eu-central-1"
          "aws:SourceVpce"      = "vpce-test"
        }
      }
    }]
    error_message = "the task may invoke only GPT OSS 20B through the one Frankfurt endpoint"
  }

  # Widening the endpoint policy or swapping in the execution role breaks this assertion.
  assert {
    condition = jsondecode(aws_vpc_endpoint.staging_qa_bedrock[0].policy).Statement == [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "bedrock:InvokeModel"
      Resource  = "arn:aws:bedrock:eu-central-1::foundation-model/openai.gpt-oss-20b-1:0"
      Condition = {
        ArnEquals = { "aws:PrincipalArn" = aws_iam_role.staging_qa_analyzer_task[0].arn }
      }
    }]
    error_message = "the endpoint admits only the analyzer task role to invoke the approved model"
  }

  assert {
    condition     = one([for s in jsondecode(aws_ecs_task_definition.staging_qa_analyzer[0].container_definitions)[0].secrets : s.valueFrom if s.name == "OSRA_STAGING_QA_SYSTEM_PROMPT"]) == var.staging_qa_analyzer.prompt_secret_arn && !contains([for s in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].secrets : s.name], "OSRA_STAGING_QA_SYSTEM_PROMPT")
    error_message = "only the analyzer receives a reference to the approved prompt"
  }
}

run "disarmed_qa_analyzer_has_no_model_or_api_access" {
  command = plan

  variables {
    api_image           = "example/api:test"
    allowed_account_ids = [format("%012d", 0)]
    staging_qa_analyzer = {
      image_digest        = "sha256:${sha256("qa-image")}"
      frankfurt_vpc_cidr  = format("%d.%d.%d.%d/%d", 10, 40, 0, 0, 24)
      prompt_secret_arn   = format("arn:aws:secretsmanager:eu-north-1:%012d:secret:test-prompt", 0)
      approval_secret_arn = format("arn:aws:secretsmanager:eu-north-1:%012d:secret:test-approval", 0)
      pairing_secret_arn  = format("arn:aws:secretsmanager:eu-north-1:%012d:secret:test-pairing", 0)
    }
  }

  override_resource {
    target          = aws_vpc_endpoint.staging_qa_bedrock[0]
    override_during = plan

    values = {
      id = "vpce-test"
      dns_entry = [{
        dns_name       = "vpce-test.example.internal"
        hosted_zone_id = "ZTEST"
      }]
    }
  }

  assert {
    condition     = length(aws_ecs_service.staging_qa_analyzer) == 1 && length(aws_iam_role_policy.staging_qa_analyzer_task) == 0
    error_message = "staging can keep the analyzer provisioned without granting model access"
  }

  assert {
    condition     = one([for item in jsondecode(aws_ecs_task_definition.staging_qa_analyzer[0].container_definitions)[0].environment : item.value if item.name == "OSRA_STAGING_QA_ANALYZER_ENABLED"]) == "0" && length(jsondecode(aws_ecs_task_definition.staging_qa_analyzer[0].container_definitions)[0].secrets) == 0
    error_message = "a disarmed analyzer has a disabled endpoint and receives no fixture secrets"
  }

  # Moving the URL outside the armed condition would give a disarmed task this setting.
  assert {
    condition     = !contains([for item in jsondecode(aws_ecs_task_definition.staging_qa_analyzer[0].container_definitions)[0].environment : item.name], "OSRA_STAGING_QA_BEDROCK_ENDPOINT_URL")
    error_message = "a disarmed analyzer receives no Bedrock endpoint URL"
  }

  assert {
    condition = !anytrue([
      for item in concat(
        jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment,
        jsondecode(aws_ecs_task_definition.api.container_definitions)[0].secrets
      ) : startswith(item.name, "OSRA_STAGING_QA_") || item.name == "OSRA_DEPLOYMENT_SCOPE"
    ])
    error_message = "a disarmed analyzer adds no QA environment variables or secrets to the API"
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
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
  assert {
    condition     = one([for p in aws_db_parameter_group.postgres.parameter : p.value if p.name == "rds.force_ssl"]) == "1" && aws_db_instance.main.parameter_group_name == aws_db_parameter_group.postgres.name
    error_message = "the database must require TLS through its own parameter group (#766 item 9)"
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.api_https.from_port == 443 && aws_vpc_security_group_egress_rule.api_https.to_port == 443 && aws_vpc_security_group_egress_rule.api_to_rds.from_port == 5432 && aws_vpc_security_group_egress_rule.api_to_redis.from_port == 6379
    error_message = "API tasks may leave only on 443, plus PostgreSQL and Redis inside the VPC (#766 item 6)"
  }
  assert {
    condition     = length(random_password.db) == 0 && length(aws_secretsmanager_secret_version.database_url) == 0 && aws_db_instance.main.manage_master_user_password
    error_message = "production keeps no database password in state: RDS manages the master, production-secrets.sh writes the API's (#766 items 1, 3)"
  }
  assert {
    condition     = !contains([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : x.name], "REDIS_URL") && contains([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].secrets : x.name], "REDIS_URL")
    error_message = "production's REDIS_URL carries the AUTH token, so it must be a secrets entry"
  }
  assert {
    condition     = contains([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : "${x.name}=${x.value}"], "DATABASE_TLS_VERIFY=required")
    error_message = "production must set DATABASE_TLS_VERIFY=required (#777)"
  }
  assert {
    condition     = length(aws_ecs_task_definition.db_admin) == 1 && strcontains(local.db_admin_script, "sslaccept=strict&sslcert=/app/certs/rds-eu-central-1-rsa2048-g1.pem") && !strcontains(local.db_admin_script, "rds-global-bundle.pem") && !strcontains(local.db_admin_script, "verify-full")
    error_message = "the db-admin task must exist and connect with Prisma's verifying TLS form against the single eu-central-1 RDS root (#919)"
  }
  assert {
    condition     = [for x in jsondecode(aws_ecs_task_definition.db_admin[0].container_definitions)[0].secrets : x.valueFrom][0] == "arn:aws:secretsmanager:eu-central-1:000000000000:secret:rds-master:password::"
    error_message = "the db-admin task must read the master password from the RDS-managed secret"
  }
  assert {
    condition     = length(aws_flow_log.vpc) == 1 && length(aws_wafv2_web_acl_logging_configuration.api) == 1 && aws_db_instance.main.enabled_cloudwatch_logs_exports == toset(["postgresql"])
    error_message = "production needs VPC flow, WAF and PostgreSQL logs (#766 item 2)"
  }
  assert {
    condition     = length(aws_lb.main.access_logs) == 0 || !anytrue([for l in aws_lb.main.access_logs : l.enabled])
    error_message = "ALB access logs must stay off: they would store the WebSocket ticket from the query string (#782)"
  }
  assert {
    condition     = length([for f in aws_wafv2_web_acl_logging_configuration.api[0].redacted_fields : f if length(f.query_string) == 1]) == 1 && toset(flatten([for f in aws_wafv2_web_acl_logging_configuration.api[0].redacted_fields : [for h in f.single_header : h.name]])) == toset(["authorization", "cookie", "x-familyshield-signature"])
    error_message = "WAF logs must redact the query string, authorization, cookie and x-familyshield-signature (#782)"
  }
  assert {
    condition     = strcontains(aws_kms_key.alarms[0].policy, "aws:SourceAccount")
    error_message = "the alarm key's service statement must be limited to this account (#782)"
  }
  assert {
    condition     = aws_cloudwatch_log_group.waf[0].retention_in_days == 90 && aws_cloudwatch_log_group.postgresql[0].retention_in_days == 90 && one([for r in aws_s3_bucket_lifecycle_configuration.access_logs[0].rule : r.expiration[0].days]) == 90
    error_message = "every production access log is kept exactly 90 days (privacy policy)"
  }
  assert {
    condition     = aws_sns_topic.alarms[0].kms_master_key_id == aws_kms_key.alarms[0].arn && length(aws_cloudwatch_event_target.guardduty_high) == 1
    error_message = "the alarm topic must use a key CloudWatch and EventBridge can use, and GuardDuty high findings must reach it"
  }
  assert {
    condition     = aws_db_instance.main.kms_key_id == aws_kms_key.rds[0].arn && length(aws_backup_selection.rds) == 1
    error_message = "production's database must use its own key and be in the daily backup plan (#766 item 5)"
  }
  assert {
    condition     = one([for r in aws_backup_plan.main[0].rule : one([for c in r.copy_action : c.lifecycle[0].delete_after])]) == 14 && one([for r in aws_backup_plan.main[0].rule : r.lifecycle[0].delete_after]) == 14
    error_message = "backups and their off-site copies are deleted after 14 days (privacy notice, #892 section 6)"
  }
  assert {
    condition     = length(aws_cloudwatch_event_target.rds_key_danger) == 1 && strcontains(aws_cloudwatch_event_rule.rds_key_danger[0].event_pattern, "ScheduleKeyDeletion")
    error_message = "a deletion or disable of the database key must alarm (#783 review)"
  }
  assert {
    condition     = length(aws_sns_topic_subscription.alarms_email_secondary) == 1
    error_message = "production alarms must reach a second address (#766 item 6)"
  }
  assert {
    condition     = length(random_password.db) == 0
    error_message = "a production plan must create no random value in env: every secret is generated out of band (#781 review B2)"
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.db_admin[0].container_definitions)[0] != null && aws_ecs_task_definition.db_admin[0].execution_role_arn == aws_iam_role.db_admin_execution[0].arn && aws_ecs_task_definition.db_admin[0].execution_role_arn != aws_ecs_task_definition.api.execution_role_arn && aws_iam_role_policy.db_admin_secrets[0].role == aws_iam_role.db_admin_execution[0].id
    error_message = "the db-admin task must have its own execution role, separate from the API's (#781 review)"
  }
  assert {
    condition     = strcontains(local.db_admin_script, "PASSWORD '$verifier'") && !strcontains(local.db_admin_script, "PASSWORD '$API_DB_PASSWORD'")
    error_message = "osra_api's password must reach PostgreSQL only as a SCRAM verifier (#781 review B3)"
  }
  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.family_plan) == 2 && length(aws_cloudwatch_metric_alarm.family_plan) == 2 && aws_cloudwatch_log_metric_filter.family_plan["family-plan-recovery-ceiling"].pattern == "{ $.event = \"family_plan_recovery_ceiling\" }" && aws_cloudwatch_log_metric_filter.family_plan["family-plan-missing-expiry"].pattern == "{ $.event = \"family_plan_missing_expiry\" }"
    error_message = "production must alarm on both family plan entitlement warnings (#811, #816)"
  }
  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.family_plan : length(a.alarm_actions) == 1 && length(coalesce(a.ok_actions, [])) == 0])
    error_message = "family plan alarms mail on ALARM only, not on every return to OK (#816 R3)"
  }
}

run "apns_off_by_default_and_mapped_when_enabled" {
  command = apply

  variables {
    api_image    = "example/api:test"
    apns_enabled = true
    apns_key_id  = "ABCDE12345"
    apns_team_id = "FGHIJ67890"
  }

  assert {
    condition = alltrue([
      contains([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].secrets : x.name], "APNS_KEY_P8"),
      one([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].secrets : x.valueFrom if x.name == "APNS_KEY_P8"]) == "arn:aws:secretsmanager:eu-central-1:000000000000:secret:apns",
      one([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : x.value if x.name == "APNS_ENV"]) == "production",
      one([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : x.value if x.name == "APNS_BUNDLE_ID"]) == "com.osratech.parent",
      one([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : x.value if x.name == "APNS_DEVICE_BUNDLE_ID"]) == "com.osratech.child",
      !contains([for x in jsondecode(aws_ecs_task_definition.api.container_definitions)[0].environment : x.name], "APNS_KEY_P8"),
    ])
    error_message = "apns_enabled maps the key as a secrets entry only, the ids and bundle ids as settings, and the production endpoint (#695)"
  }
}

run "apns_needs_both_ids" {
  command = plan

  variables {
    api_image    = "example/api:test"
    apns_enabled = true
    apns_key_id  = "ABCDE12345"
  }

  expect_failures = [aws_ecs_task_definition.api]
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
    cors_origin              = ""
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_alarm_email_secondary" {
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
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_secrets_out_of_band" {
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
    alarm_email_secondary    = "oncall@example.test"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_audit_logs_enabled" {
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

run "production_requires_offsite_backup_copy" {
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
    alarm_email_secondary    = "oncall@example.test"
    secrets_out_of_band      = true
    audit_logs_enabled       = true
    db_customer_kms_key      = true
    backup_copy_account_id   = "111111111111"
    backup_copy_vault_arn    = "arn:aws:backup:eu-central-1:111111111111:backup-vault:same-region"
    cors_origin              = "https://app.example.test"
    allowed_account_ids      = ["000000000000"]
    assume_role_arn          = "arn:aws:iam::000000000000:role/test-deploy"
  }

  expect_failures = [terraform_data.production_guard]
}

# Closed-beta option (#892 section 6): the daily backup stays in Frankfurt, with no copy to eu-west-1.
# The guard must accept it, the in-account plan and its 14-day lifecycle stay, and no copy_action is planned.
run "production_offsite_copy_off" {
  command = apply

  variables {
    environment                 = "production"
    region                      = "eu-central-1"
    api_image                   = "example/api:test"
    api_cpu                     = 1024
    api_memory                  = 2048
    api_min_count               = 2
    api_max_count               = 6
    nat_gateway_count           = 2
    db_instance_class           = "db.t4g.small"
    db_multi_az                 = true
    db_allocated_storage        = 50
    db_max_allocated_storage    = 200
    db_backup_retention_days    = 14
    db_deletion_protection      = true
    db_skip_final_snapshot      = false
    db_performance_insights     = true
    redis_num_nodes             = 2
    redis_failover              = true
    redis_transit_encryption    = true
    alb_deletion_protection     = true
    waf_enabled                 = true
    alarms_enabled              = true
    alarm_email                 = "alerts@example.test"
    alarm_email_secondary       = "oncall@example.test"
    secrets_out_of_band         = true
    audit_logs_enabled          = true
    db_customer_kms_key         = true
    backup_copy_account_id      = "111111111111"
    backup_copy_vault_arn       = "arn:aws:backup:eu-west-1:111111111111:backup-vault:osra-production-copy"
    cors_origin                 = "https://app.example.test"
    allowed_account_ids         = ["000000000000"]
    assume_role_arn             = "arn:aws:iam::000000000000:role/test-deploy"
    backup_offsite_copy_enabled = false
  }

  assert {
    condition     = length(aws_backup_plan.main) == 1 && length(aws_backup_selection.rds) == 1
    error_message = "with the off-site copy off, production still has its daily in-account backup plan"
  }
  assert {
    condition     = alltrue([for r in aws_backup_plan.main[0].rule : length(r.copy_action) == 0 && r.lifecycle[0].delete_after == 14])
    error_message = "backup_offsite_copy_enabled = false must plan no copy_action, and keep the 14-day lifecycle"
  }
  assert {
    condition     = !strcontains(aws_kms_key.rds[0].policy, "BackupCopyAccountReads")
    error_message = "with the off-site copy off, no other account may read the database key"
  }
}

run "environment_must_be_staging_or_production" {
  command = plan

  variables {
    environment = "prod"
    api_image   = "example/api:test"
  }

  expect_failures = [var.environment]
}
