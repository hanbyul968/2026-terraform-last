# ═══════════════════════════════════════════════════════════════
# WAF  (과제 13)
#   - Name: wsc2026-waf / CLOUDFRONT scope (us-east-1)
#   - CloudFront 에 연결
#   - SQL Injection / XSS 차단 + Rate Limit(1분 200개 초과 차단)
#
# 채점 10-1: SQLi 403 / XSS 403 / Rate PASS(403)
# ═══════════════════════════════════════════════════════════════

resource "aws_wafv2_web_acl" "cdn" {
  provider = aws.use1
  name     = local.waf_name
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # ── SQL Injection ──
  rule {
    name     = "sqli"
    priority = 1
    action {
      block {}
    }
    statement {
      sqli_match_statement {
        field_to_match {
          query_string {}
        }
        text_transformation {
          priority = 0
          type     = "URL_DECODE"
        }
        text_transformation {
          priority = 1
          type     = "HTML_ENTITY_DECODE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "sqli"
      sampled_requests_enabled   = true
    }
  }

  # ── XSS ──
  rule {
    name     = "xss"
    priority = 2
    action {
      block {}
    }
    statement {
      xss_match_statement {
        field_to_match {
          query_string {}
        }
        text_transformation {
          priority = 0
          type     = "URL_DECODE"
        }
        text_transformation {
          priority = 1
          type     = "HTML_ENTITY_DECODE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "xss"
      sampled_requests_enabled   = true
    }
  }

  # ── Rate Limit : 1분간 동일 IP 200개 초과 차단 ──
  rule {
    name     = "rate-limit"
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit                 = 200
        aggregate_key_type    = "IP"
        evaluation_window_sec = 60
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.waf_name
    sampled_requests_enabled   = true
  }

  tags = { Name = local.waf_name }
}
