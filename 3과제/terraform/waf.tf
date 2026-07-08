# WAFv2 attached to CloudFront (scope=CLOUDFRONT, must live in us-east-1).
#
# ===== 운영 원칙 (대회날): "관찰 → 차단" =====
# 1) 기본 상태에서는 AWS 관리형 룰(공격 시그니처 기반, 정상 요청 오탐 거의 없음)만 켜져 있다.
#    임의 커스텀 차단 룰은 전부 변수(waf_blocked_*)이고 기본값이 비어 있음
#    → 처음에는 아무 정상 요청도 오차단하지 않는다 (가용성 점수 최우선).
# 2) 트래픽 시작 후 관찰:
#      python ..\tuning\waf_header_stats.py --log-group aws-waf-logs-<project> --region us-east-1 --hours 1
#    → "아직 안 막힌 비정상 요청" + 추가할 tfvars 제안까지 출력해준다.
# 3) 차단은 변수로만 추가 (waf.tf 수정 불필요). terraform.tfvars 또는 -var 로:
#      waf_blocked_user_agents   = ["sqlmap", "nikto", "attack"]        # UA에 포함되면 403
#      waf_blocked_headers       = ["x-junk", "x-debug"]                # 헤더가 존재하면 403
#      waf_blocked_header_values = [{ header = "referer", value = "evil.com" }]
#      waf_blocked_body_patterns = ["$ne", "sleep("]                    # body에 포함되면 403
#      waf_block_private_xff     = true                                 # XFF 위조(사설IP) 403
#    확신 없으면 waf_custom_rule_action = "count" 로 먼저 넣고 로그 확인 후 "block".
# 4) 커스텀 룰은 모두 "유효 엔드포인트"(local.waf_block_scope_regex)에서만 동작한다.
#    미정의 경로(/.env 등)는 커스텀 룰을 건너뛰고 ALB default 404 → 스펙(403/404 구분) 준수.
#
# NOTE: "direct-to-ALB"(origin-verify) 검사는 여기 없음 — CloudFront WAF 는
# CloudFront 가 X-Origin-Verify 헤더를 넣기 전(viewer 단계)에 실행되므로 볼 수 없다.
# 그 검사는 ALB 리스너 규칙(alb.tf)에 있고 여전히 403 을 반환한다.

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

  # ---------- 커스텀 룰 (변수 기반, 기본 비활성) ----------
  # 각 룰의 action 은 var.waf_custom_rule_action ("block" | "count") 을 따른다.

  # (1) 악성 User-Agent — var.waf_blocked_user_agents 가 비어있지 않으면 생성
  dynamic "rule" {
    for_each = length(var.waf_blocked_user_agents) > 0 ? [1] : []
    content {
      name     = "BlockedUserAgents"
      priority = 1
      action {
        dynamic "block" {
          for_each = var.waf_custom_rule_action == "block" ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = var.waf_custom_rule_action == "count" ? [1] : []
          content {}
        }
      }
      statement {
        and_statement {
          statement {
            regex_match_statement {
              regex_string = local.waf_block_scope_regex
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
            regex_match_statement {
              regex_string = "(${join("|", [for ua in var.waf_blocked_user_agents : lower(ua)])})"
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
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "blocked-user-agents"
        sampled_requests_enabled   = true
      }
    }
  }

  # (2) X-Forwarded-For 위조 (루프백/사설/메타데이터 IP) — var.waf_block_private_xff = true 면 생성
  dynamic "rule" {
    for_each = var.waf_block_private_xff ? [1] : []
    content {
      name     = "SpoofedForwardedFor"
      priority = 2
      action {
        dynamic "block" {
          for_each = var.waf_custom_rule_action == "block" ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = var.waf_custom_rule_action == "count" ? [1] : []
          content {}
        }
      }
      statement {
        and_statement {
          statement {
            regex_match_statement {
              regex_string = local.waf_block_scope_regex
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
            regex_match_statement {
              regex_string = "(^|,)\\s*(127\\.|10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|169\\.254\\.)"
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
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "spoofed-xff"
        sampled_requests_enabled   = true
      }
    }
  }

  # (3) 비정상 헤더 존재 — var.waf_blocked_headers 의 헤더가 "있기만 하면" 차단 (헤더당 룰 1개)
  dynamic "rule" {
    for_each = { for i, h in var.waf_blocked_headers : lower(h) => i }
    content {
      name     = "BlockedHeader-${replace(rule.key, "/[^a-z0-9-]/", "-")}"
      priority = 40 + rule.value
      action {
        dynamic "block" {
          for_each = var.waf_custom_rule_action == "block" ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = var.waf_custom_rule_action == "count" ? [1] : []
          content {}
        }
      }
      statement {
        and_statement {
          statement {
            regex_match_statement {
              regex_string = local.waf_block_scope_regex
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
            size_constraint_statement {
              comparison_operator = "GT"
              size                = 0
              field_to_match {
                single_header {
                  name = rule.key
                }
              }
              text_transformation {
                priority = 0
                type     = "NONE"
              }
            }
          }
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "blocked-header-${replace(rule.key, "/[^a-z0-9-]/", "-")}"
        sampled_requests_enabled   = true
      }
    }
  }

  # (4) 특정 헤더 "값" 에 문자열 포함 — var.waf_blocked_header_values (항목당 룰 1개)
  dynamic "rule" {
    for_each = { for i, hv in var.waf_blocked_header_values : i => hv }
    content {
      name     = "BlockedHeaderValue-${rule.key}"
      priority = 50 + tonumber(rule.key)
      action {
        dynamic "block" {
          for_each = var.waf_custom_rule_action == "block" ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = var.waf_custom_rule_action == "count" ? [1] : []
          content {}
        }
      }
      statement {
        and_statement {
          statement {
            regex_match_statement {
              regex_string = local.waf_block_scope_regex
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
              search_string         = lower(rule.value.value)
              positional_constraint = "CONTAINS"
              field_to_match {
                single_header {
                  name = lower(rule.value.header)
                }
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
        metric_name                = "blocked-header-value-${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  # (5) 비정상 body 패턴 — var.waf_blocked_body_patterns (패턴당 룰 1개).
  # 정상 요청 body 에 절대 없는 토큰만 넣을 것 (오탐 = 가용성 점수 하락).
  dynamic "rule" {
    for_each = { for i, p in var.waf_blocked_body_patterns : i => p }
    content {
      name     = "BlockedBodyPattern-${rule.key}"
      priority = 60 + tonumber(rule.key)
      action {
        dynamic "block" {
          for_each = var.waf_custom_rule_action == "block" ? [1] : []
          content {}
        }
        dynamic "count" {
          for_each = var.waf_custom_rule_action == "count" ? [1] : []
          content {}
        }
      }
      statement {
        and_statement {
          statement {
            regex_match_statement {
              regex_string = local.waf_block_scope_regex
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
              search_string         = lower(rule.value)
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
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "blocked-body-${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  # ---------- AWS 관리형 룰 (항상 켜짐, 시그니처 기반이라 정상 요청 안전) ----------
  # scope_down = 유효 API 경로(local.api_path_regex)만 → 미정의 경로(/.env, /v1/users 등)는
  # 관리형 룰을 건너뛰고 ALB default 로 가서 404 (403 아님, 스펙 준수).
  # 경로가 바뀌면 var.api_prefix 또는 var.api_paths_override 만 수정.

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
        scope_down_statement {
          regex_match_statement {
            regex_string = local.api_path_regex
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
          regex_match_statement {
            regex_string = local.api_path_regex
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
          regex_match_statement {
            regex_string = local.api_path_regex
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
# 관찰: python ..\tuning\waf_header_stats.py --log-group aws-waf-logs-<project> --region us-east-1 --hours 1
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
