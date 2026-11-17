# --- WAF on the API load balancer (production, #714) -------------------------------------------
# AWS managed rule groups block known-bad patterns; the per-IP rate rule starts in count mode so the
# first weeks show real traffic before it may block a family behind a shared address (a school or a
# mobile carrier's NAT). The API keeps its own per-route limits either way.

locals {
  waf_managed_groups = {
    # name = priority
    AWSManagedRulesAmazonIpReputationList = 10
    AWSManagedRulesKnownBadInputsRuleSet  = 20
    AWSManagedRulesCommonRuleSet          = 30
  }
}

resource "aws_wafv2_web_acl" "api" {
  count = var.waf_enabled ? 1 : 0

  name  = "${local.name_prefix}-api"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.waf_managed_groups
    content {
      name     = rule.key
      priority = rule.value

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.key
          vendor_name = "AWS"

          # The Common set blocks request bodies over 8 KB. Some API bodies (a batch of usage events,
          # a rules document) can exceed that legitimately, so that one rule only counts.
          dynamic "rule_action_override" {
            for_each = rule.key == "AWSManagedRulesCommonRuleSet" ? ["SizeRestrictions_BODY"] : []
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name_prefix}-${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "per-ip-rate"
    priority = 40

    action {
      dynamic "count" {
        for_each = var.waf_rate_action == "count" ? [1] : []
        content {}
      }
      dynamic "block" {
        for_each = var.waf_rate_action == "block" ? [1] : []
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-per-ip-rate"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-api"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${local.name_prefix}-api"
  }
}

resource "aws_wafv2_web_acl_association" "api" {
  count = var.waf_enabled ? 1 : 0

  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.api[0].arn
}
