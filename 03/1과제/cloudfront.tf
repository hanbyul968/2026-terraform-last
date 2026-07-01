# ═══════════════════════════════════════════════════════════════
# CloudFront  (과제 13)  — wsc2026-cdn
#   단일 도메인 / 3개 Origin:
#     기본 /        -> S3(정적, OAC, 캐싱 활성)         + default_root_object
#     /booking      -> ALB Origin (POST, 캐싱 비활성)   -> /v1/book 로 rewrite
#     /v1/book      -> Lambda Function URL (GET, 캐싱 비활성)
#   WAF(wsc2026-waf) 연결
#
# 채점 9-1: CF 도메인 200
# 채점 9-2: S3 CachingOptimized / ALB·Lambda CachingDisabled
# 채점 9-3: POST /booking -> booking_id, GET /v1/book?booking_id -> 데이터
# ═══════════════════════════════════════════════════════════════

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "wsc2026-s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# /booking -> /v1/book URI 재작성 (book 앱 POST 엔드포인트)
resource "aws_cloudfront_function" "rewrite_booking" {
  name    = "wsc2026-rewrite-booking"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var req = event.request;
      if (req.uri === '/booking' || req.uri.indexOf('/booking') === 0) {
        req.uri = '/v1/book';
      }
      return req;
    }
  EOT
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

locals {
  lambda_url_domain = replace(replace(aws_lambda_function_url.book_get.function_url, "https://", ""), "/", "")
}

resource "aws_cloudfront_distribution" "this" {
  count               = var.deploy_cdn ? 1 : 0
  enabled             = true
  is_ipv6_enabled     = true
  price_class         = "PriceClass_All"
  comment             = local.cdn_name
  default_root_object = "index.html"
  web_acl_id          = aws_wafv2_web_acl.cdn.arn

  # ── Origin 1: S3 (정적) ──
  origin {
    domain_name              = aws_s3_bucket.static.bucket_regional_domain_name
    origin_id                = "s3-static"
    origin_path              = "/static"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  # ── Origin 2: ALB (book 앱 POST) ──
  origin {
    domain_name = data.aws_lb.app[0].dns_name
    origin_id   = "alb-app"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # ── Origin 3: Lambda Function URL (GET) ──
  origin {
    domain_name = local.lambda_url_domain
    origin_id   = "lambda-get"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # 기본 -> S3 (캐싱 활성)
  default_cache_behavior {
    target_origin_id       = "s3-static"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id
  }

  # /booking -> ALB (캐싱 비활성, POST, /v1/book 로 rewrite)
  ordered_cache_behavior {
    path_pattern             = "/booking"
    target_origin_id         = "alb-app"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.rewrite_booking.arn
    }
  }

  # /v1/book -> Lambda (캐싱 비활성, GET)
  ordered_cache_behavior {
    path_pattern             = "/v1/book"
    target_origin_id         = "lambda-get"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = local.cdn_name }
}
