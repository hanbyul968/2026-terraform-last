# ═══════════════════════════════════════════════════════════════
# CloudFront  (과제 14) + WAF 연결
#   - Name: wsc-cdn (태그)
#   - Origin: S3(정적, 캐싱) + ALB(VPC Origin, 캐싱X, 쿼리스트링 전달)
#   - Internal ALB 를 VPC Origin 으로 연결
#   - HTTP -> HTTPS redirect, IPv6 비활성화, PriceClass_All
#   - 하나의 CloudFront 만 생성
# 채점 8-1: PriceClass_All / IsIPV6Enabled False
# 채점 8-2: S3 는 Hit, http 접근 시 301 redirect
# ═══════════════════════════════════════════════════════════════

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "wsc-s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Internal ALB 를 향하는 VPC Origin
resource "aws_cloudfront_vpc_origin" "app_lb" {
  vpc_origin_endpoint_config {
    name                   = "wsc-app-lb-vpc-origin"
    arn                    = aws_lb.app.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

# 정적(S3) 캐시 정책 / 동적(ALB) 캐시 비활성 + 전체 쿼리스트링 전달
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
  is_ipv6_enabled     = false
  price_class         = "PriceClass_All"
  comment             = "wsc-cdn"
  default_root_object = "index.html"

  # S3 origin (정적). origin_path=/static => /index.html -> static/index.html
  origin {
    domain_name              = aws_s3_bucket.static.bucket_regional_domain_name
    origin_id                = "s3-static"
    origin_path              = "/static"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  # ALB origin (동적, VPC Origin)
  origin {
    domain_name = aws_lb.app.dns_name
    origin_id   = "alb-app"
    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.app_lb.id
    }
  }

  # 기본 => S3 (캐싱)
  default_cache_behavior {
    target_origin_id       = "s3-static"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  # /v1/* => ALB (캐싱X, 쿼리스트링 전달, 모든 메서드)
  ordered_cache_behavior {
    path_pattern             = "/v1/*"
    target_origin_id         = "alb-app"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  web_acl_id = aws_wafv2_web_acl.cdn.arn

  tags = { Name = "wsc-cdn" }
}
