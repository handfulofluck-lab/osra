data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Two AZs because an ALB requires at least two subnets in different AZs; the second no longer
  # backs an RDS standby now that staging runs single-AZ by default.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# Public subnets hold only the ALB and the NAT gateway; tasks and data stay private.
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${count.index + 1}"
  }
}

# Private subnets carry the Fargate tasks, PostgreSQL and ElastiCache.
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 10)
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.name_prefix}-private-${count.index + 1}"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_eip" "nat" {
  count  = var.nat_gateway_count
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.main]
}

# Staging: ONE NAT gateway for both private subnets. Cost over HA, deliberately: a second NAT adds
# roughly US$39/month plus data processing to a stack that is destroyed after each session.
# Production (#714): one per AZ, so losing an AZ does not also cut the surviving tasks' route out.
resource "aws_nat_gateway" "main" {
  count         = var.nat_gateway_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${local.name_prefix}-nat-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table per NAT gateway: staging's two private subnets share one table and NAT;
# production gives each AZ its own.
resource "aws_route_table" "private" {
  count  = var.nat_gateway_count
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name = var.nat_gateway_count == 1 ? "${local.name_prefix}-private" : "${local.name_prefix}-private-${count.index + 1}"
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[min(count.index, var.nat_gateway_count - 1)].id
}

# The NAT pieces became counted in #714; these keep a live staging env from being replaced by the rename.
moved {
  from = aws_eip.nat
  to   = aws_eip.nat[0]
}

moved {
  from = aws_nat_gateway.main
  to   = aws_nat_gateway.main[0]
}

moved {
  from = aws_route_table.private
  to   = aws_route_table.private[0]
}

# --- Security groups -------------------------------------------------------------------------
# Rules are separate resources, not inline blocks: inline ingress/egress on two SGs that reference
# each other creates a dependency cycle in Terraform.

resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "Public ALB: HTTP/HTTPS from allowed ranges, forwarding only to API tasks."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

resource "aws_security_group" "api" {
  name        = "${local.name_prefix}-api"
  description = "Fargate API tasks: ALB ingress, outbound to ECR, logs, RDS and ElastiCache."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-api"
  }
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds"
  description = "PostgreSQL: port 5432 from API tasks only. No public CIDR anywhere."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-rds"
  }
}

resource "aws_security_group" "redis" {
  name        = "${local.name_prefix}-redis"
  description = "ElastiCache: port 6379 from API tasks only."
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-redis"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from an allowed client range"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = local.https_enabled ? toset(var.allowed_cidrs) : toset([])

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from an allowed client range (only when base has a certificate)"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_api" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward requests (and health checks) to API tasks"
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "api_from_alb" {
  security_group_id            = aws_security_group.api.id
  description                  = "API traffic from the ALB only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 3000
  to_port                      = 3000
  ip_protocol                  = "tcp"
}

# Tasks leave the VPC only over HTTPS (#766 item 6): ECR pulls, CloudWatch Logs, Secrets Manager, Resend,
# FCM, APNs and the AI engine all speak 443. Inside the VPC they reach only PostgreSQL and Redis. DNS to
# the VPC resolver is not filtered by security groups, so it needs no rule.
resource "aws_vpc_security_group_egress_rule" "api_https" {
  security_group_id = aws_security_group.api.id
  description       = "HTTPS to AWS APIs and external providers through the NAT"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "api_to_rds" {
  security_group_id            = aws_security_group.api.id
  description                  = "PostgreSQL"
  referenced_security_group_id = aws_security_group.rds.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "api_to_redis" {
  security_group_id            = aws_security_group.api.id
  description                  = "Redis"
  referenced_security_group_id = aws_security_group.redis.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_api" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from API tasks"
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_api" {
  security_group_id            = aws_security_group.redis.id
  description                  = "ElastiCache from API tasks"
  referenced_security_group_id = aws_security_group.api.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
}
