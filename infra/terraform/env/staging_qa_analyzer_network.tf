locals {
  staging_qa_enabled   = var.staging_qa_analyzer != null
  staging_qa_armed     = try(var.staging_qa_analyzer.armed, false)
  staging_qa_frankfurt = "eu-central-1"
  staging_qa_model_arn = "arn:aws:bedrock:${local.staging_qa_frankfurt}::foundation-model/openai.gpt-oss-20b-1:0"
  staging_qa_dns       = "analyzer.qa.internal"
}

# ADR-0033 §4. The Stockholm analyzer reaches a same-account Frankfurt interface
# endpoint over peering, without a public Bedrock route or production resources.
data "aws_availability_zones" "staging_qa_frankfurt" {
  count  = local.staging_qa_enabled ? 1 : 0
  region = local.staging_qa_frankfurt
  state  = "available"
}

resource "aws_vpc" "staging_qa_frankfurt" {
  count  = local.staging_qa_enabled ? 1 : 0
  region = local.staging_qa_frankfurt

  cidr_block           = var.staging_qa_analyzer.frankfurt_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_subnet" "staging_qa_frankfurt" {
  count  = local.staging_qa_enabled ? 2 : 0
  region = local.staging_qa_frankfurt

  vpc_id            = aws_vpc.staging_qa_frankfurt[0].id
  cidr_block        = cidrsubnet(var.staging_qa_analyzer.frankfurt_vpc_cidr, 1, count.index)
  availability_zone = data.aws_availability_zones.staging_qa_frankfurt[0].names[count.index]
}

resource "aws_subnet" "staging_qa_analyzer" {
  count = local.staging_qa_enabled ? 2 : 0

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index + 20)
  availability_zone = local.azs[count.index]
}

resource "aws_vpc_peering_connection" "staging_qa" {
  count = local.staging_qa_enabled ? 1 : 0

  vpc_id      = aws_vpc.main.id
  peer_vpc_id = aws_vpc.staging_qa_frankfurt[0].id
  peer_region = local.staging_qa_frankfurt
}

resource "aws_vpc_peering_connection_accepter" "staging_qa" {
  count  = local.staging_qa_enabled ? 1 : 0
  region = local.staging_qa_frankfurt

  vpc_peering_connection_id = aws_vpc_peering_connection.staging_qa[0].id
  auto_accept               = true
}

resource "aws_route_table" "staging_qa_analyzer" {
  count  = local.staging_qa_enabled ? 1 : 0
  vpc_id = aws_vpc.main.id

  # The existing NAT provides ECR, Secrets Manager and CloudWatch bootstrap.
  # The task role requires the Frankfurt VPC endpoint even if DNS or routing drift.
  route {
    cidr_block     = aws_vpc_security_group_egress_rule.api_https.cidr_ipv4
    nat_gateway_id = aws_nat_gateway.main[0].id
  }

  route {
    cidr_block                = var.staging_qa_analyzer.frankfurt_vpc_cidr
    vpc_peering_connection_id = aws_vpc_peering_connection_accepter.staging_qa[0].id
  }
}

resource "aws_route_table_association" "staging_qa_analyzer" {
  count = local.staging_qa_enabled ? 2 : 0

  subnet_id      = aws_subnet.staging_qa_analyzer[count.index].id
  route_table_id = aws_route_table.staging_qa_analyzer[0].id
}

resource "aws_route_table" "staging_qa_frankfurt" {
  count  = local.staging_qa_enabled ? 1 : 0
  region = local.staging_qa_frankfurt
  vpc_id = aws_vpc.staging_qa_frankfurt[0].id

  dynamic "route" {
    for_each = aws_subnet.staging_qa_analyzer

    content {
      cidr_block                = route.value.cidr_block
      vpc_peering_connection_id = aws_vpc_peering_connection_accepter.staging_qa[0].id
    }
  }
}

resource "aws_route_table_association" "staging_qa_frankfurt" {
  count  = local.staging_qa_enabled ? 2 : 0
  region = local.staging_qa_frankfurt

  subnet_id      = aws_subnet.staging_qa_frankfurt[count.index].id
  route_table_id = aws_route_table.staging_qa_frankfurt[0].id
}

resource "aws_security_group" "staging_qa_bedrock" {
  count  = local.staging_qa_enabled ? 1 : 0
  region = local.staging_qa_frankfurt

  name        = "${local.name_prefix}-qa-bedrock"
  description = "Frankfurt Bedrock endpoint for staging QA"
  vpc_id      = aws_vpc.staging_qa_frankfurt[0].id
}

resource "aws_vpc_security_group_ingress_rule" "staging_qa_bedrock" {
  count  = local.staging_qa_enabled ? 2 : 0
  region = local.staging_qa_frankfurt

  security_group_id = aws_security_group.staging_qa_bedrock[0].id
  description       = "HTTPS from the peered analyzer subnet"
  cidr_ipv4         = aws_subnet.staging_qa_analyzer[count.index].cidr_block
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_endpoint" "staging_qa_bedrock" {
  count  = local.staging_qa_enabled ? 1 : 0
  region = local.staging_qa_frankfurt

  vpc_id              = aws_vpc.staging_qa_frankfurt[0].id
  vpc_endpoint_type   = "Interface"
  service_name        = "com.amazonaws.${local.staging_qa_frankfurt}.bedrock-runtime"
  subnet_ids          = aws_subnet.staging_qa_frankfurt[*].id
  security_group_ids  = [aws_security_group.staging_qa_bedrock[0].id]
  private_dns_enabled = false
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "bedrock:InvokeModel"
      Resource  = local.staging_qa_model_arn
      Condition = {
        ArnEquals = {
          "aws:PrincipalArn" = aws_iam_role.staging_qa_analyzer_task[0].arn
        }
      }
    }]
  })
}
