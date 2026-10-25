# --- Cluster ----------------------------------------------------------------------------------

resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-api"

  # Container Insights has a per-metric charge; staging uses task logs and ALB metrics instead.
  setting {
    name  = "containerInsights"
    value = "disabled"
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
          # The API fail-closes parent sessions when Redis is unreachable, so this must point at
          # the ElastiCache node from elasticache.tf, never localhost.
          { name = "REDIS_URL", value = "redis://${aws_elasticache_replication_group.main.primary_endpoint_address}:6379" },
        ],
        var.cors_origin != "" ? [{ name = "CORS_ORIGIN", value = var.cors_origin }] : [],
        # Roadmap 5.8: count a device's request rate so "idle child phone <= 3 requests per 10 min" can be
        # measured. Staging only — production leaves it unset on purpose (#346 review): the counter keeps a
        # hash per device, and the durable-revocation fix pins this cache to `maxmemory-policy noeviction`, so
        # telemetry that filled memory would make revocation writes fail. Logouts answering 5xx because of a
        # counter is the trade this flag refuses. Staging carries it so #346's reviewer can measure the Flip4.
        var.environment == "staging" ? [{ name = "IDLE_BUDGET_COUNTING", value = "1" }] : [],
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
          # The seed refuses to run in production without it, and the image must not carry a default.
          { name = "SEED_DEMO_PASSWORD", valueFrom = data.terraform_remote_state.base.outputs.demo_password_secret_arn },
        ],
        var.push_enabled ? [
          { name = "FCM_SERVICE_ACCOUNT_JSON", valueFrom = data.terraform_remote_state.base.outputs.fcm_service_account_secret_arn },
        ] : [],
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

  # On-demand staging: `down` must not need a console step.
  enable_deletion_protection = false
  drop_invalid_header_fields = true

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

  # ADR-0028's minimum: two copies so one task can die without an outage.
  desired_count = 2
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

  depends_on = [
    aws_db_instance.main,
    aws_elasticache_replication_group.main,
    aws_lb_listener.http,
    aws_secretsmanager_secret_version.database_url,
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

  # ADR-0028: minimum two copies; four is enough for staging's expected traffic.
  min_capacity = 2
  max_capacity = 4
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
