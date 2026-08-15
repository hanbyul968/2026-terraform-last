# ---------------------------------------------------------------------------
# CloudFront : 사용자에게 제공되는 "단일 https 엔드포인트".
#   - 기본 인증서(*.cloudfront.net) 사용 -> 도메인/ACM 없이 https 확보
#   - 원본 = ALB (http-only)
#   - 캐시 비활성(랜덤 색상 응답은 캐싱 금지) + 전 요청/쿼리스트링 원본 전달
#     (문제지: requestid, uuid 쿼리스트링 변조 금지)
# ---------------------------------------------------------------------------

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = "${local.name} color single endpoint"
  price_class     = var.cloudfront_price_class
  is_ipv6_enabled = true

  origin {
    origin_id   = "alb"
    domain_name = aws_lb.this.dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "${local.name}-cf" }
}
