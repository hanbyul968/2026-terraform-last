# ═══════════════════════════════════════════════════════════════
# WAF  (과제 13)
#   - Name: wsc-waf, CLOUDFRONT scope => us-east-1 에 생성
#   - POST 요청 Body 에 admin 또는 sysop(대소문자 무시) 포함 시 Block
# 채점 9-1: SearchString 디코드 결과에 admin, sysop 포함
# ═══════════════════════════════════════════════════════════════

resource "aws_wafv2_web_acl" "cdn" {
  provider = aws.use1
  name     = "wsc-waf"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "block-admin-body"
    priority = 1
    action {
      block {}
    }
    statement {
      and_statement {
        statement {
          byte_match_statement {
            search_string         = "admin"
            positional_constraint = "CONTAINS"
            field_to_match {
              body {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
        statement {
          byte_match_statement {
            search_string         = "post"
            positional_constraint = "EXACTLY"
            field_to_match {
              method {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "block-admin-body"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "block-sysop-body"
    priority = 2
    action {
      block {}
    }
    statement {
      and_statement {
        statement {
          byte_match_statement {
            search_string         = "sysop"
            positional_constraint = "CONTAINS"
            field_to_match {
              body {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
        statement {
          byte_match_statement {
            search_string         = "post"
            positional_constraint = "EXACTLY"
            field_to_match {
              method {}
            }
            text_transformation {
              priority = 0
              type     = "LOWERCASE"
            }
          }
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "block-sysop-body"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "wsc-waf"
    sampled_requests_enabled   = true
  }

  tags = { Name = "wsc-waf" }
}
