# WAFv2 attached to CloudFront (scope=CLOUDFRONT, must live in us-east-1).
# Inspects VIEWER requests at the edge: bad uuid → 403, plus AWS managed rules.
# Unknown paths still return 404 via the ALB default action.
#
# NOTE: the "direct-to-ALB" (origin-verify) check is NOT here — CloudFront WAF
# runs before CloudFront injects the X-Origin-Verify header, so it can't see it.
# That check lives on the ALB as a listener rule (see alb.tf) and still 403s.

# Secret shared between CloudFront (injects header) and the ALB listener rule
# (verifies it). Requests without it didn't come through CloudFront → 403.
resource "random_password" "origin_verify" {
  length  = 40
  special = false
}

resource "aws_wafv2_web_acl" "cloudfront" {
  provider    = aws.us_east_1
  name        = "${local.name}-acl"
  description = "Edge WAF for CloudFront - blocks abnormal requests with 403"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # 악성 User-Agent (sqlmap 등 스캐너, "attack") → 403
  rule {
    name     = "BadUserAgent"
    priority = 3
    action {
      block {}
    }
    statement {
      regex_match_statement {
        regex_string = "(sqlmap|nikto|nmap|masscan|acunetix|havij|attack)"
        field_to_match {
          single_header {
            name = "user-agent"
          }
        }
        text_transformation {
          priority = 0
          type     = "LOWERCASE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "bad-user-agent"
      sampled_requests_enabled   = true
    }
  }

  # X-Forwarded-For 위조(루프백/사설 IP 삽입) → 403
  rule {
    name     = "SpoofedForwardedFor"
    priority = 4
    action {
      block {}
    }
    statement {
      byte_match_statement {
        search_string         = "127.0.0.1"
        positional_constraint = "CONTAINS"
        field_to_match {
          single_header {
            name = "x-forwarded-for"
          }
        }
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "spoofed-xff"
      sampled_requests_enabled   = true
    }
  }

  # 비정상 커스텀 헤더(X-Junk) 존재 → 403
  rule {
    name     = "OversizedJunkHeader"
    priority = 5
    action {
      block {}
    }
    statement {
      size_constraint_statement {
        comparison_operator = "GT"
        size                = 0
        field_to_match {
          single_header {
            name = "x-junk"
          }
        }
        text_transformation {
          priority = 0
          type     = "NONE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "junk-header"
      sampled_requests_enabled   = true
    }
  }

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
        # 유효 엔드포인트에만 관리형 룰 적용 → 미정의 경로(/.env, /v1/users 등)는
        # 관리형 룰을 건너뛰고 ALB default 로 가서 404 (403 아님, 스펙 준수).
        scope_down_statement {
          or_statement {
            statement {
              byte_match_statement {
                search_string         = "/v1/user"
                positional_constraint = "EXACTLY"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "/v1/product"
                positional_constraint = "EXACTLY"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "/v1/stress"
                positional_constraint = "EXACTLY"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
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
        scope_down_statement {
          or_statement {
            statement {
              byte_match_statement {
                search_string         = "/v1/user"
                positional_constraint = "EXACTLY"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "/v1/product"
                positional_constraint = "EXACTLY"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "/v1/stress"
                positional_constraint = "EXACTLY"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
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
        scope_down_statement {
          or_statement {
            statement {
              byte_match_statement {
                search_string         = "/v1/user"
                positional_constraint = "EXACTLY"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "/v1/product"
                positional_constraint = "EXACTLY"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
            statement {
              byte_match_statement {
                search_string         = "/v1/stress"
                positional_constraint = "EXACTLY"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
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


# ----- WAF 로깅 (CloudFront scope → 반드시 us-east-1) -----
# 로그그룹 이름은 반드시 "aws-waf-logs-" 로 시작해야 한다 (WAF 요구사항).
# 모니터링: dashboard.py --waf-log-group aws-waf-logs-<project> --waf-region us-east-1
resource "aws_cloudwatch_log_group" "waf" {
  provider          = aws.us_east_1
  name              = "aws-waf-logs-${local.name}"
  retention_in_days = 7
}

resource "aws_wafv2_web_acl_logging_configuration" "cloudfront" {
  provider                = aws.us_east_1
  resource_arn            = aws_wafv2_web_acl.cloudfront.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
}
