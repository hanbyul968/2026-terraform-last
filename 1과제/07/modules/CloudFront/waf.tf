# WAF Web ACL (us-east-1 for CloudFront)
resource "aws_wafv2_web_acl" "this" {
  provider = aws.us_east_1
  name     = var.waf_name
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # AWSManagedRulesCommonRuleSet
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # AWSManagedRulesKnownBadInputsRuleSet
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

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
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rate Limiting Rule
  rule {
    name     = "unicorn-rate-limit"
    priority = 3

    action {
      block {
        custom_response {
          response_code = 403
          custom_response_body_key = "blocked"
        }
      }
    }

    statement {
      rate_based_statement {
        limit              = 50
        evaluation_window_sec = 60
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "unicorn-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  custom_response_body {
    key          = "blocked"
    content_type = "TEXT_PLAIN"
    content      = "Request blocked by Unicorn WAF"
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.waf_name
    sampled_requests_enabled   = true
  }

  tags = {
    Name = var.waf_name
  }
}

# WAF Logging
resource "aws_cloudwatch_log_group" "waf" {
  provider   = aws.us_east_1
  name       = "aws-waf-logs-unicorn"

  tags = {
    Name = "aws-waf-logs-unicorn"
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  provider                = aws.us_east_1
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.this.arn
}
