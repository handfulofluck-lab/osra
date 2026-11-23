# --- Cluster ----------------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-api"

  # Container Insights has a per-metric charge; staging uses task logs and ALB metrics instead.
  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }

  tags = {
    Name = "${local.name_prefix}-api"
  }
}

# --- Task definition --------------------------------------------------------------------------

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name_prefix}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.api_cpu)
  memory                   = tostring(var.api_memory)
  execution_role_arn       = data.terraform_remote_state.base.outputs.execution_role_arn

  # Graviton (ARM64) is roughly 20% cheaper per vCPU on Fargate than x86, and the API image is a
  # multi-arch node:20-alpine build. ADR-0028 also names ARM.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = var.api_image
      essential = true

      portMappings = [{
        containerPort = 3000
        hostPort      = 3000
        protocol      = "tcp"
      }]

      environment = concat(
        [
          { name = "NODE_ENV", value = "production" },
          { name = "PORT", value = "3000" },
          { name = "LOG_LEVEL", value = "info" },
          # The ALB is one proxy hop: the API takes the client address from the X-Forwarded-For entry the ALB
          # appends, so every rate limit keys on the client, not on the balancer. A hop count, never `true`
          # (that trusts the entry the caller writes). A CDN in front of the ALB would make this 2.
          { name = "TRUST_PROXY", value = "1" },
        ],
        # The API fail-closes parent sessions when Redis is unreachable, so this must point at the ElastiCache
        # node from elasticache.tf, never localhost. Production's URL carries the AUTH token, so it arrives as
        # a secrets entry instead (below).
        var.secrets_out_of_band ? [] : [{ name = "REDIS_URL", value = local.redis_url }],
        # The API refuses to boot when this is set and DATABASE_URL does not verify the server certificate
        # (#777): production's URL is written with Prisma's strict form by production-secrets.sh.
        var.secrets_out_of_band ? [{ name = "DATABASE_TLS_VERIFY", value = "required" }] : [],
        var.app_public_url != "" ? [{ name = "APP_PUBLIC_URL", value = var.app_public_url }] : [],
        var.email_provider != "" ? [{ name = "EMAIL_PROVIDER", value = var.email_provider }] : [],
        var.email_from != "" ? [{ name = "EMAIL_FROM", value = var.email_from }] : [],
        # Empty cors_origin = the API's permissive default, which it now refuses under NODE_ENV=production
        # unless told it is deliberate (#765). Production can never get here: its guard requires cors_origin.
        var.cors_origin != "" ? [{ name = "CORS_ORIGIN", value = var.cors_origin }] : [{ name = "CORS_ALLOW_ANY_ORIGIN", value = "1" }],
        # Roadmap 5.8: count a device's request rate so "idle child phone <= 3 requests per 10 min" can be
        # measured. Staging only — production leaves it unset on purpose (#346 review): the counter keeps a
        # hash per device, and the durable-revocation fix pins this cache to `maxmemory-policy noeviction`, so
        # telemetry that filled memory would make revocation writes fail. Logouts answering 5xx because of a
        # counter is the trade this flag refuses. Staging carries it so #346's reviewer can measure the Flip4.
        var.environment == "staging" ? [{ name = "IDLE_BUDGET_COUNTING", value = "1" }] : [],
        local.staging_qa_armed ? [
          { name = "OSRA_DEPLOYMENT_SCOPE", value = "staging" },
          { name = "OSRA_STAGING_QA_ANALYZER_ENABLED", value = "1" },
          { name = "OSRA_STAGING_QA_ANALYZER_URL", value = "http://${local.staging_qa_dns}:8000" },
        ] : [],
        local.staging_qa_pair_text,
        # APNs (#695). Always the production APNs endpoint: TestFlight and store builds carry
        # aps-environment=production, and a sandbox token sent there fails with BadDeviceToken. Key and team
        # ids are not secrets but stay out of the repo; they come from tfvars.
        var.apns_enabled ? [
          { name = "APNS_KEY_ID", value = var.apns_key_id },
          { name = "APNS_TEAM_ID", value = var.apns_team_id },
          { name = "APNS_BUNDLE_ID", value = var.apns_bundle_id },
          { name = "APNS_DEVICE_BUNDLE_ID", value = var.apns_device_bundle_id },
          { name = "APNS_ENV", value = "production" },
        ] : [],
      )

      # Secrets are injected from Secrets Manager, never baked into the task definition.
      # push_enabled adds the FCM service account (roadmap 1.5). It stays out of the list by default
      # because a secret with no version cannot be resolved by ECS, and the task would fail to start
      # before anyone has run put-secret-value. Turn it on only after the value exists.
      secrets = concat(
        [
          { name = "DATABASE_URL", valueFrom = data.terraform_remote_state.base.outputs.database_url_secret_arn },
          { name = "JWT_SECRET", valueFrom = data.terraform_remote_state.base.outputs.jwt_secret_arn },
          { name = "VAULT_KEY", valueFrom = data.terraform_remote_state.base.outputs.vault_key_secret_arn },
        ],
        # Staging's seed needs it. Production never seeds (up.sh migrates only), so its tasks do not get the
        # demo password at all (Fable's review of #765).
        var.environment != "production" ? [
          { name = "SEED_DEMO_PASSWORD", valueFrom = data.terraform_remote_state.base.outputs.demo_password_secret_arn },
        ] : [],
        var.push_enabled ? [
          { name = "FCM_SERVICE_ACCOUNT_JSON", valueFrom = data.terraform_remote_state.base.outputs.fcm_service_account_secret_arn },
        ] : [],
        var.apns_enabled ? [
          { name = "APNS_KEY_P8", valueFrom = data.terraform_remote_state.base.outputs.apns_key_p8_secret_arn },
        ] : [],
        # Production's service credential (#714): a `secrets` entry, never `environment`, so the value is in
        # no task definition. try(): a staging base from before this change has no such output.
        var.secrets_out_of_band ? [
          { name = "REDIS_URL", valueFrom = data.terraform_remote_state.base.outputs.redis_url_secret_arn },
        ] : [],
        try(data.terraform_remote_state.base.outputs.internal_hmac_secret_arn, "") != "" ? [
          { name = "INTERNAL_HMAC_SECRET", valueFrom = data.terraform_remote_state.base.outputs.internal_hmac_secret_arn },
        ] : [],
        local.staging_qa_armed ? concat(local.staging_qa_approval, [
          { name = "OSRA_STAGING_QA_CHILD_ID", valueFrom = "${var.staging_qa_analyzer.pairing_secret_arn}:child_id::" },
          { name = "OSRA_STAGING_QA_DEVICE_ID", valueFrom = "${var.staging_qa_analyzer.pairing_secret_arn}:device_id::" },
        ]) : [],
      )

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = data.terraform_remote_state.base.outputs.log_group_name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "api"
        }
      }

      stopTimeout = 30
    }
  ])

  tags = {
    Name = "${local.name_prefix}-api"
  }

  # APNs with an empty key or team id would start a task whose every iPhone push fails at signing.
  lifecycle {
    precondition {
      condition     = !var.apns_enabled || (var.apns_key_id != "" && var.apns_team_id != "")
      error_message = "apns_enabled needs apns_key_id and apns_team_id in tfvars."
    }
  }
}

# --- Load balancer ----------------------------------------------------------------------------

resource "aws_lb" "main" {
  name               = "${local.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  # WebSocket clients (parent live view) would be dropped by the 60 s default.
  idle_timeout = 300

  # On-demand staging: `down` must not need a console step. Production protects it.
  enable_deletion_protection = var.alb_deletion_protection
  drop_invalid_header_fields = true

  # No ALB access logs (#782 review): they record the full request line, query string included, and the
  # WebSocket ticket travels in the query string. WAF logs (query string redacted) cover who called what.

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

resource "aws_lb_target_group" "api" {
  name        = "${local.name_prefix}-api"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  # Faster rolling deploys; production can raise this if connections are long-lived.
  deregistration_delay = 30

  health_check {
    enabled = true
    # Liveness endpoint from services/api/src/routes/health.ts (intentionally dependency-free).
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${local.name_prefix}-api"
  }
}

# Port 80 is a 301 to HTTPS whenever base has a certificate, and forwards plaintext otherwise.
# Non-release mode therefore serves HTTP (no 443 listener exists); see README.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = local.https_enabled ? "redirect" : "forward"

    dynamic "redirect" {
      for_each = local.https_enabled ? [1] : []
      content {
        protocol    = "HTTPS"
        port        = "443"
        status_code = "HTTP_301"
      }
    }

    dynamic "forward" {
      for_each = local.https_enabled ? [] : [1]
      content {
        target_group {
          arn = aws_lb_target_group.api.arn
        }
      }
    }
  }

  # Non-release mode forwards the API in cleartext over the internet, so require a narrowed range.
  lifecycle {
    precondition {
      condition     = local.https_enabled || !contains(var.allowed_cidrs, "0.0.0.0/0")
      error_message = "No certificate in base, so port 80 would serve the API in cleartext to the whole internet. Narrow allowed_cidrs (for example your own address/32) or use release mode."
    }
  }
}

# No certificate in base means no HTTPS listener at all, not a broken one.
resource "aws_lb_listener" "https" {
  count = local.https_enabled ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = local.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# --- Service and autoscaling ------------------------------------------------------------------

# Gated on api_service_enabled because the API exits at boot when the schema is empty or drifted
# (services/api/src/lib/schemaSync.ts), and Terraform waits for a new ECS service to become stable.
# up.sh applies with the gate off, seeds, then applies again to create a service that can pass.
resource "aws_ecs_service" "api" {
  count = var.api_service_enabled ? 1 : 0

  name            = "${local.name_prefix}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn

  # ADR-0028's minimum: two copies so one task can die without an outage. Autoscaling owns the count
  # afterwards, so a later apply must not reset it (ignore_changes below).
  desired_count = var.api_min_count
  launch_type   = "FARGATE"

  # `up` must fail here rather than print a URL for a service whose tasks are crash-looping.
  wait_for_steady_state = true

  platform_version = "1.4.0"

  health_check_grace_period_seconds  = 60
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # Roll back automatically when a new task definition never becomes healthy.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.api.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 3000
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_db_instance.main,
    aws_elasticache_replication_group.main,
    aws_lb_listener.http,
    aws_secretsmanager_secret_version.database_url,
    aws_ecs_service.staging_qa_analyzer,
    aws_iam_role_policy.staging_qa_api_execution,
  ]

  tags = {
    Name = "${local.name_prefix}-api"
  }
}

resource "aws_appautoscaling_target" "ecs" {
  count = var.api_service_enabled ? 1 : 0

  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api[0].name}"

  # ADR-0028: minimum two copies; staging tops out at four, production at six (#714).
  min_capacity = var.api_min_count
  max_capacity = var.api_max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.api_service_enabled ? 1 : 0

  name               = "${local.name_prefix}-api-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = aws_appautoscaling_target.ecs[0].resource_id

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_policy" "requests" {
  count = var.api_service_enabled ? 1 : 0

  name               = "${local.name_prefix}-api-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = aws_appautoscaling_target.ecs[0].resource_id

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      # Requests per target per minute. 1000 is a staging-sized trigger; production should tune
      # this from measured per-family traffic (ADR-0028's requests-per-child model).
      resource_label = "${aws_lb.main.arn_suffix}/${aws_lb_target_group.api.arn_suffix}"
    }
    target_value       = 1000
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
