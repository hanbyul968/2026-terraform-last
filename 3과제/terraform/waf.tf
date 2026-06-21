# Regional WAFv2 attached to ALB.
# Returns 403 for abnormal requests (per problem spec).
# Unknown paths return 404 via ALB default action (not WAF).
resource "aws_wafv2_web_acl" "regional" {
  name        = "${local.name}-acl"
  description = "Blocks abnormal requests with 403"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Custom block response: 403 JSON
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
        # Exclude size-restriction rules for image upload (PUT /v1/product carries images)
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            allow {}
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 30
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "sqli"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-acl"
    sampled_requests_enabled   = true
  }
}


# ----- WAF 로깅 (모니터링 대시보드의 block/403 분석용) -----
# 로그그룹 이름은 반드시 "aws-waf-logs-" 로 시작해야 한다 (WAF 요구사항).
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${local.name}"
  retention_in_days = 7
}

resource "aws_wafv2_web_acl_logging_configuration" "regional" {
  resource_arn            = aws_wafv2_web_acl.regional.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
}