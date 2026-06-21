provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

resource "aws_wafv2_web_acl" "acl" {
  provider = aws.us_east_1
  name     = "gj2026-waf-acl"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  custom_response_body {
    key          = "method-not-allowed"
    content      = "Method Not Allowed"
    content_type = "TEXT_PLAIN"
  }

  custom_response_body {
    key          = "access-denied"
    content      = "Access Denied"
    content_type = "TEXT_PLAIN"
  }

  rule {
    name     = "block-non-post-methods"
    priority = 1

    action {
      block {
        custom_response {
          response_code            = 405
          custom_response_body_key = "method-not-allowed"
        }
      }
    }

    statement {
      and_statement {
        statement {
          byte_match_statement {
            search_string         = "/v1/book"
            positional_constraint = "STARTS_WITH"
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
          not_statement {
            statement {
              byte_match_statement {
                search_string         = "POST"
                positional_constraint = "EXACTLY"
                field_to_match {
                  method {}
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
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "block-non-post-methods"
    }
  }

  rule {
    name     = "validate-client-id"
    priority = 2

    action {
      block {
        custom_response {
          response_code            = 403
          custom_response_body_key = "access-denied"
        }
      }
    }

    statement {
      and_statement {
        statement {
          byte_match_statement {
            search_string         = "client_id"
            positional_constraint = "CONTAINS"
            field_to_match {
              query_string {}
            }
            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
        statement {
          not_statement {
            statement {
              regex_match_statement {
                regex_string = "client_id=[A-Za-z][A-Za-z0-9]*[0-9][A-Za-z0-9]*(&|$)"
                field_to_match {
                  query_string {}
                }
                text_transformation {
                  priority = 0
                  type     = "URL_DECODE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
      metric_name                = "validate-client-id"
    }
  }

  visibility_config {
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
    metric_name                = "gj2026-waf-acl"
  }
}
