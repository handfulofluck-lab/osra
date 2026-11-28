# Load-test stack only (loadtest/README.md, load-test plan of 27 Nov 2026). Everything here is gated on
# `loadtest_mode`, which only infra/terraform/loadtest.sh sets and the production guard refuses, so staging and
# production plans are unchanged.
#
# What it adds to a stack that is otherwise staging/production-shaped:
#   - API env: OSRA_DEPLOYMENT_SCOPE=loadtest (the API then honours RATE_LIMIT_GLOBAL_MAX, lib/rateLimits.ts),
#     AI_ENGINE_URL pointing at a stub sidecar, LOG_LEVEL=warn (see ecs.tf).
#   - an `ai-stub` sidecar in the API task: loadtest/ai-stub/server.mjs run from the public node image, so a social
#     scan costs 300 ms and no Bedrock call. No image to build.
#   - a k6 task definition and a security group for the load generators. They run in the PRIVATE subnets and reach the
#     ALB through the NAT gateway, so the ALB admits exactly the NAT's address and nothing else is opened.

variable "loadtest_mode" {
  description = "Load-test stack only (loadtest.sh). Never true for staging or production; production's guard refuses it."
  type        = bool
  default     = false
}

variable "loadtest_rate_limit_max" {
  description = "Per-address global rate limit on the load-test stack. The generators send thousands of simulated phones from one NAT address."
  type        = number
  default     = 1000000
}

variable "loadtest_stub_delay_ms" {
  description = "How long the AI stub takes to answer /analyze, in ms (the real engine's p50 is about 300)."
  type        = number
  default     = 300
}

variable "loadtest_stub_image" {
  description = "Public Node image the AI stub runs on (Node standard library only)."
  type        = string
  default     = "public.ecr.aws/docker/library/node:20-alpine"
}

variable "loadtest_k6_image" {
  description = "k6 image for the load generators. Pin a version; never :latest."
  type        = string
  default     = "grafana/k6:0.57.0"
}

locals {
  loadtest_env = var.loadtest_mode ? [
    { name = "OSRA_DEPLOYMENT_SCOPE", value = "loadtest" },
    { name = "RATE_LIMIT_GLOBAL_MAX", value = tostring(var.loadtest_rate_limit_max) },
    { name = "AI_ENGINE_URL", value = "http://localhost:8000" },
  ] : []

  loadtest_sidecars = var.loadtest_mode ? [{
    name              = "ai-stub"
    image             = var.loadtest_stub_image
    essential         = false
    memoryReservation = 64
    command           = ["node", "--input-type=module", "-e", file("${path.module}/../../../loadtest/ai-stub/server.mjs")]
    environment       = [{ name = "STUB_DELAY_MS", value = tostring(var.loadtest_stub_delay_ms) }, { name = "STUB_PORT", value = "8000" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = data.terraform_remote_state.base.outputs.log_group_name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ai-stub"
      }
    }
  }] : []
}

# The generators reach the ALB through the NAT gateway: admit exactly its address(es), on port 80 (the load-test
# stack has no certificate, so the precondition in ecs.tf already refuses 0.0.0.0/0).
resource "aws_vpc_security_group_ingress_rule" "alb_from_loadtest_nat" {
  count = var.loadtest_mode ? var.nat_gateway_count : 0

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the load generators (via NAT)"
  cidr_ipv4         = "${aws_eip.nat[count.index].public_ip}/32"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_security_group" "loadtest_k6" {
  count = var.loadtest_mode ? 1 : 0

  name        = "${local.name_prefix}-k6"
  description = "Load generators: out only (ALB on 80, image and script pulls on 443)"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-k6" }
}

resource "aws_vpc_security_group_egress_rule" "loadtest_k6_out" {
  for_each = var.loadtest_mode ? toset(["80", "443"]) : toset([])

  security_group_id = aws_security_group.loadtest_k6[0].id
  description       = "Out on ${each.value}"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  ip_protocol       = "tcp"
}

resource "aws_ecs_task_definition" "loadtest_k6" {
  count = var.loadtest_mode ? 1 : 0

  family                   = "${local.name_prefix}-k6"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "4096"
  memory                   = "8192"
  execution_role_arn       = data.terraform_remote_state.base.outputs.execution_role_arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  # The script and its arguments come from `aws ecs run-task --overrides` (loadtest.sh run), so one definition
  # serves every scenario. JWT_SECRET is the load-test stack's OWN secret (its own base), never staging's.
  container_definitions = jsonencode([{
    name      = "k6"
    image     = var.loadtest_k6_image
    essential = true
    secrets   = [{ name = "JWT_SECRET", valueFrom = data.terraform_remote_state.base.outputs.jwt_secret_arn }]
    environment = [
      { name = "BASE_URL", value = "http://${aws_lb.main.dns_name}" },
      { name = "K6_NO_USAGE_REPORT", value = "true" },
    ]
    ulimits = [{ name = "nofile", softLimit = 65536, hardLimit = 65536 }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = data.terraform_remote_state.base.outputs.log_group_name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "k6"
      }
    }
  }])

  tags = { Name = "${local.name_prefix}-k6" }
}

output "loadtest_k6_task_definition_arn" {
  description = "k6 task definition (load-test stack only)."
  value       = var.loadtest_mode ? aws_ecs_task_definition.loadtest_k6[0].arn : ""
}

output "loadtest_k6_security_group_id" {
  description = "Security group for the k6 tasks (load-test stack only)."
  value       = var.loadtest_mode ? aws_security_group.loadtest_k6[0].id : ""
}

# loadtest_mode and the loadtest environment go together: a staging stack cannot switch the mode on, and a stack
# named loadtest cannot run without it (it would then be an unlabelled copy of staging with real-looking settings).
#
# And a load-test env must read the LOAD-TEST base (Codex's review of #1281): env/secrets.tf writes DATABASE_URL into
# the secret named by base's state, so a loadtest env reading staging's base would repoint live staging at the test
# database. The key and bucket are pinned here, not left to tfvars, and checked as a precondition ON
# data.terraform_remote_state.base (remote_state.tf), so a wrong key fails before the state is ever read.
locals {
  loadtest_base_state_key = "loadtest/base/terraform.tfstate"
  loadtest_state_bucket   = "osra-terraform-state-222207908538-eu-north-1"
}

resource "terraform_data" "loadtest_guard" {
  lifecycle {
    precondition {
      condition     = var.loadtest_mode == (var.environment == "loadtest")
      error_message = "loadtest_mode must be true exactly when environment = \"loadtest\"."
    }
  }
}
