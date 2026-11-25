locals {
  staging_qa_account = try(tolist(var.allowed_account_ids)[0], "")
  staging_qa_repo    = "${local.name_prefix}/qa-ai-engine"
  staging_qa_task_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.staging_qa_account }
        ArnLike      = { "aws:SourceArn" = "arn:aws:ecs:${var.region}:${local.staging_qa_account}:*" }
      }
    }]
  })

  # Explicit provider selector for API and analyzer (#962). Unset means the services' default, bedrock.
  staging_qa_engine = local.staging_qa_armed ? [
    { name = "OSRA_STAGING_QA_ENGINE", value = try(var.staging_qa_analyzer.engine, "bedrock") },
  ] : []
  staging_qa_pair_text = local.staging_qa_armed && try(var.staging_qa_analyzer.allow_synthetic_pair_text, false) ? [
    { name = "OSRA_STAGING_QA_ALLOW_SYNTHETIC_PAIR_TEXT", value = "1" },
  ] : []

  staging_qa_approval = local.staging_qa_armed ? [
    { name = "OSRA_STAGING_QA_EXPIRES_AT", valueFrom = "${var.staging_qa_analyzer.approval_secret_arn}:expires_at::" },
    { name = "OSRA_STAGING_QA_FIXTURE_SHA256", valueFrom = "${var.staging_qa_analyzer.approval_secret_arn}:fixture_sha256::" },
  ] : []
}

resource "aws_security_group" "staging_qa_analyzer" {
  count = local.staging_qa_enabled ? 1 : 0

  name        = "${local.name_prefix}-qa-ai-engine"
  description = "Private synthetic QA analyzer"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "staging_qa_from_api" {
  count = local.staging_qa_enabled ? 1 : 0

  security_group_id            = aws_security_group.staging_qa_analyzer[0].id
  referenced_security_group_id = aws_security_group.api.id
  description                  = "Analyzer requests from staging API only"
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

resource "aws_vpc_security_group_egress_rule" "staging_qa_from_api" {
  count = local.staging_qa_enabled ? 1 : 0

  security_group_id            = aws_security_group.api.id
  referenced_security_group_id = aws_security_group.staging_qa_analyzer[0].id
  description                  = "Staging API to the private QA analyzer"
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

resource "aws_vpc_security_group_egress_rule" "staging_qa_analyzer_https" {
  count = local.staging_qa_enabled ? 1 : 0

  security_group_id = aws_security_group.staging_qa_analyzer[0].id
  cidr_ipv4         = aws_vpc_security_group_egress_rule.api_https.cidr_ipv4
  description       = "HTTPS for ECS bootstrap and the endpoint-only Bedrock role"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_service_discovery_private_dns_namespace" "staging_qa" {
  count = local.staging_qa_enabled ? 1 : 0
  name  = "qa.internal"
  vpc   = aws_vpc.main.id
}

resource "aws_service_discovery_service" "staging_qa" {
  count = local.staging_qa_enabled ? 1 : 0
  name  = "analyzer"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.staging_qa[0].id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }

  health_check_custom_config {}

  # AWS does not return the empty block, so without this every plan forces a replacement, and the
  # delete fails while tasks are registered (#962, 23 Nov).
  lifecycle {
    ignore_changes = [health_check_custom_config]
  }
}

resource "aws_cloudwatch_log_group" "staging_qa_analyzer" {
  count = local.staging_qa_enabled ? 1 : 0

  name              = "/ecs/${local.name_prefix}-qa-ai-engine"
  retention_in_days = 14
}

resource "aws_iam_role" "staging_qa_analyzer_task" {
  count = local.staging_qa_enabled ? 1 : 0

  name               = "${local.name_prefix}-qa-ai-engine-task"
  assume_role_policy = local.staging_qa_task_trust
}

resource "aws_iam_role_policy" "staging_qa_analyzer_task" {
  count = local.staging_qa_armed ? 1 : 0
  role  = aws_iam_role.staging_qa_analyzer_task[0].id
  name  = "InvokeApprovedFrankfurtModel"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "bedrock:InvokeModel"
      Resource = local.staging_qa_model_arn
      Condition = {
        StringEquals = {
          "aws:RequestedRegion" = local.staging_qa_frankfurt
          "aws:SourceVpce"      = aws_vpc_endpoint.staging_qa_bedrock[0].id
        }
      }
    }]
  })
}

resource "aws_iam_role" "staging_qa_analyzer_execution" {
  count = local.staging_qa_enabled ? 1 : 0

  name               = "${local.name_prefix}-qa-ai-engine-execution"
  assume_role_policy = local.staging_qa_task_trust
}

resource "aws_iam_role_policy" "staging_qa_analyzer_execution" {
  count = local.staging_qa_enabled ? 1 : 0
  role  = aws_iam_role.staging_qa_analyzer_execution[0].id
  name  = "PullAndStartAnalyzer"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = ["arn:aws:ecr:${var.region}:${local.staging_qa_account}:repository/${local.staging_qa_repo}"]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${trimsuffix(aws_cloudwatch_log_group.staging_qa_analyzer[0].arn, ":*")}:log-stream:*"]
      },
      ], local.staging_qa_armed ? [{
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          var.staging_qa_analyzer.prompt_secret_arn,
          var.staging_qa_analyzer.approval_secret_arn,
        ]
    }] : [])
  })
}

resource "aws_iam_role_policy" "staging_qa_api_execution" {
  count = local.staging_qa_armed ? 1 : 0
  role  = data.terraform_remote_state.base.outputs.execution_role_name
  name  = "ReadStagingQaTestScope"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "secretsmanager:GetSecretValue"
      Resource = [
        var.staging_qa_analyzer.approval_secret_arn,
        var.staging_qa_analyzer.pairing_secret_arn,
      ]
    }]
  })
}

locals {
  staging_qa_large_task = local.staging_qa_armed && try(var.staging_qa_analyzer.own_model_task_size, false)
}

resource "aws_ecs_task_definition" "staging_qa_analyzer" {
  count = local.staging_qa_enabled ? 1 : 0

  family                   = "${local.name_prefix}-qa-ai-engine"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = local.staging_qa_large_task ? "2048" : "512"
  memory                   = local.staging_qa_large_task ? "8192" : "1024"
  execution_role_arn       = aws_iam_role.staging_qa_analyzer_execution[0].arn
  task_role_arn            = aws_iam_role.staging_qa_analyzer_task[0].arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "analyzer"
    image     = "${local.staging_qa_account}.dkr.ecr.${var.region}.amazonaws.com/${local.staging_qa_repo}@${var.staging_qa_analyzer.image_digest}"
    essential = true
    portMappings = [{
      containerPort = 8000
      protocol      = "tcp"
    }]
    environment = concat(
      [
        { name = "OSRA_DEPLOYMENT_SCOPE", value = "staging" },
        { name = "OSRA_STAGING_QA_ANALYZER_ENABLED", value = local.staging_qa_armed ? "1" : "0" },
        { name = "UVICORN_ACCESS_LOG", value = "false" },
      ],
      # AWS lists the interface endpoint's regional DNS entry before its zonal entries.
      local.staging_qa_armed ? [{
        name  = "OSRA_STAGING_QA_BEDROCK_ENDPOINT_URL"
        value = "https://${aws_vpc_endpoint.staging_qa_bedrock[0].dns_entry[0].dns_name}"
      }] : [],
      local.staging_qa_pair_text,
      local.staging_qa_engine,
      local.staging_model_env,
    )
    secrets = local.staging_qa_armed ? concat(local.staging_qa_approval, [
      { name = "OSRA_STAGING_QA_SYSTEM_PROMPT", valueFrom = var.staging_qa_analyzer.prompt_secret_arn },
    ]) : []
    healthCheck = {
      command     = ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health', timeout=2).close()"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = local.staging_model_read ? 300 : 15
    }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.staging_qa_analyzer[0].name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "analyzer"
      }
    }
  }])

  lifecycle {
    # An own-model window without every receipt pin refuses each call at runtime; fail the plan instead.
    precondition {
      condition     = !(local.staging_model_read && contains(["own", "both"], try(var.staging_qa_analyzer.engine, "bedrock"))) || length(local.staging_model_receipt_pins) == 2
      error_message = "An armed own or both window that reads model archives needs v9_model_sha256, v9b_model_sha256 and thresholds_sha256."
    }
  }
}

resource "aws_ecs_service" "staging_qa_analyzer" {
  count = local.staging_qa_enabled ? 1 : 0

  name                  = "${local.name_prefix}-qa-ai-engine"
  cluster               = aws_ecs_cluster.main.id
  task_definition       = aws_ecs_task_definition.staging_qa_analyzer[0].arn
  desired_count         = 1
  launch_type           = "FARGATE"
  platform_version      = "1.4.0"
  wait_for_steady_state = true

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.staging_qa_analyzer[*].id
    security_groups  = [aws_security_group.staging_qa_analyzer[0].id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.staging_qa[0].arn
  }

  depends_on = [
    aws_iam_role_policy.staging_model_archive_read,
    aws_iam_role_policy.staging_qa_analyzer_execution,
    aws_iam_role_policy.staging_qa_analyzer_task,
    aws_vpc_endpoint.staging_qa_bedrock,
    aws_route_table_association.staging_qa_analyzer,
    aws_route_table_association.staging_qa_frankfurt,
    aws_vpc_security_group_egress_rule.staging_qa_analyzer_https,
    aws_vpc_security_group_ingress_rule.staging_qa_bedrock,
  ]
}
