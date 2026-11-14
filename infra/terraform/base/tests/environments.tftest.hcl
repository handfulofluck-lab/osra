# Plan-level checks with a mocked AWS provider (#714): no credentials, no state, runs in CI.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }
  mock_data "aws_route53_zone" {
    defaults = {
      zone_id = "ZSTAGING"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = {
      arn = "arn:aws:iam::000000000000:oidc-provider/token.actions.githubusercontent.com"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::000000000000:role/test"
    }
  }
  mock_resource "aws_ecr_repository" {
    defaults = {
      arn = "arn:aws:ecr:eu-central-1:000000000000:repository/test"
    }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:eu-central-1:000000000000:secret:test"
    }
  }
}

mock_provider "random" {}

# The production zone's id and name servers must be known at plan time for the assertions below.
override_resource {
  target          = aws_route53_zone.api
  override_during = plan
  values = {
    zone_id      = "ZPRODUCTION"
    name_servers = ["ns-1.example", "ns-2.example", "ns-3.example", "ns-4.example"]
  }
}

# The real provider knows the validation record names at plan time; a mock does not, so supply them.
override_resource {
  target          = aws_acm_certificate.api
  override_during = plan
  values = {
    arn           = "arn:aws:acm:eu-central-1:000000000000:certificate/test"
    status        = "ISSUED"
    type          = "AMAZON_ISSUED"
    key_algorithm = "RSA_2048"
    domain_validation_options = [{
      domain_name           = "api.example.test"
      resource_record_name  = "_x.api.example.test."
      resource_record_type  = "CNAME"
      resource_record_value = "_y.acm-validations.aws."
    }]
  }
}

run "staging_defaults_are_unchanged" {
  command = plan

  variables {
    github_repo      = "owner/repo"
    github_owner_id  = "1"
    github_repo_id   = "2"
    domain_name      = "api.staging.example.test"
    hosted_zone_name = "example.test"
  }

  assert {
    condition     = length(aws_route53_zone.api) == 0 && output.hosted_zone_id == "ZSTAGING"
    error_message = "staging must look its zone up, not create one"
  }
  assert {
    condition     = aws_cloudwatch_log_group.api.retention_in_days == 14 && aws_secretsmanager_secret.jwt_secret.recovery_window_in_days == 0
    error_message = "staging log retention or secret recovery window changed"
  }
  assert {
    condition     = aws_secretsmanager_secret.database_url.description == "Prisma DATABASE_URL for the OSRA staging API"
    error_message = "staging secret descriptions must stay byte-identical (an edit would update live secrets)"
  }
  assert {
    condition     = length(aws_iam_role.bedrock_eval) == 1 && length(aws_iam_role.publish) == 1
    error_message = "staging keeps the publish and Bedrock evaluation roles"
  }
  assert {
    condition     = length(aws_budgets_budget.monthly) == 0
    error_message = "staging's budget is managed outside Terraform"
  }
}

run "production_settings" {
  command = plan

  variables {
    environment                 = "production"
    region                      = "eu-central-1"
    domain_name                 = "api.example.test"
    hosted_zone_name            = "api.example.test"
    create_hosted_zone          = true
    github_repo                 = "owner/repo"
    github_owner_id             = "1"
    github_repo_id              = "2"
    bedrock_eval_role_enabled   = false
    log_retention_days          = 30
    secret_recovery_window_days = 7
    budget_limit_usd            = 400
    alarm_email                 = "alerts@example.test"
  }

  assert {
    condition     = length(aws_route53_zone.api) == 1 && output.hosted_zone_id == "ZPRODUCTION" && length(output.hosted_zone_name_servers) == 4
    error_message = "production must create its own api zone and output its name servers for the delegation"
  }
  assert {
    condition     = aws_route53_record.validation["api.example.test"].zone_id == "ZPRODUCTION"
    error_message = "the certificate must validate in the production zone"
  }
  assert {
    condition     = aws_cloudwatch_log_group.api.retention_in_days == 30 && aws_secretsmanager_secret.vault_key.recovery_window_in_days == 7
    error_message = "production log retention or recovery window wrong"
  }
  assert {
    condition     = length(aws_iam_role.bedrock_eval) == 0 && length(aws_iam_role.publish) == 1 && output.bedrock_eval_role_arn == ""
    error_message = "production publishes images over OIDC but has no Bedrock evaluation role"
  }
  assert {
    condition     = aws_budgets_budget.monthly[0].limit_amount == "400" && length(aws_budgets_budget.monthly[0].notification) == 3
    error_message = "production budget must be US$400 with three notifications"
  }
}

run "zone_creation_needs_a_name" {
  command = plan

  variables {
    create_hosted_zone = true
  }

  expect_failures = [var.create_hosted_zone]
}
