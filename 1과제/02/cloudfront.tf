# ═══════════════════════════════════════════════════════════════
# CloudFront  (과제 11)
#   - Comment(이름): wskorea26-concert-cf  (채점 사전준비에서 Comment 로 탐색)
#   - S3 origin(wskorea26-s3-origin): 정적 웹, OAC, 캐싱 ON, 헤더 wskorea26-s3-access
#   - ALB origin(wskorea26-alb-origin): custom origin(http 80), 헤더 X-Origin-Verify=wskorea26-cf
#   - 기본 동작 -> S3(redirect-to-https, 캐싱), /book* -> ALB(캐싱X, 쿼리/메서드 전달)
#   - /book POST 는 CloudFront Function 으로 /v1/book 으로 경로 재작성
# 채점 8-1: origin id/도메인, 8-2: 기본 S3 / /book* ALB / redirect-to-https
# 채점 8-3: 커스텀 헤더, 8-4: 200/301/main.jpeg
# ═══════════════════════════════════════════════════════════════

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "wskorea26-s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# /book(POST) -> /v1/book 경로 재작성 (book 앱은 /v1/book 만 처리)
resource "aws_cloudfront_function" "book_rewrite" {
  name    = "wskorea26-book-rewrite"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var req = event.request;
      if (req.method === 'POST' && req.uri === '/book') {
        req.uri = '/v1/book';
      }
      return req;
    }
  EOT
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  price_class         = "PriceClass_All" # 전세계 사용자 빠른 접근
  comment             = "wskorea26-concert-cf"
  default_root_object = "index.html"

  # S3 origin (정적). origin_path=/web/main => /index.html -> web/main/index.html
  origin {
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_id                = "wskorea26-s3-origin"
    origin_path              = "/web/main"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
    custom_header {
      name  = "wskorea26-s3-access"
      value = var.s3_access_header_value
    }
  }

  # ALB origin (custom, http only). 헤더 X-Origin-Verify 로 직접접근 차단(ALB 403)
  origin {
    domain_name = aws_lb.book.dns_name
    origin_id   = "wskorea26-alb-origin"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
    custom_header {
      name  = "X-Origin-Verify"
      value = var.cf_origin_verify
    }
  }

  # 기본 => S3 (캐싱 ON)
  default_cache_behavior {
    target_origin_id       = "wskorea26-s3-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  # /book* => ALB (캐싱 X, 쿼리스트링/메서드 전달)
  ordered_cache_behavior {
    path_pattern             = "/book*"
    target_origin_id         = "wskorea26-alb-origin"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.book_rewrite.arn
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "wskorea26-concert-cf" }
}
