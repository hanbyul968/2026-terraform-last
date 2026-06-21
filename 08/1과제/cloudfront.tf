# =============================================================================
# 5. CloudFront
#  - 오리진 2개: S3(정적) + ALB(API)
#  - 기본 경로(/), 정적 파일 -> S3 오리진
#  - /v1/*, /health -> ALB 오리진
#  - Default Root Object: index.html
# =============================================================================

# S3 오리진 접근용 OAC
resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${local.prefix}-s3-oac"
  description                       = "OAC for ${local.bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# AWS 관리형 캐시/오리진 요청 정책
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

locals {
  s3_origin_id  = "s3-${local.bucket_name}"
  alb_origin_id = "alb-${local.prefix}-book"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  comment             = "${local.prefix} concert booking service"
  default_root_object = "index.html"
  price_class         = "PriceClass_200"

  # ---- 오리진 1: S3 (정적) ----
  origin {
    domain_name              = aws_s3_bucket.static.bucket_regional_domain_name
    origin_id                = local.s3_origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  # ---- 오리진 2: ALB (API) ----
  origin {
    domain_name = aws_lb.book.dns_name
    origin_id   = local.alb_origin_id

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # ALB Listener가 HTTP:80
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # ---- 기본 동작: 정적 -> S3 ----
  default_cache_behavior {
    target_origin_id       = local.s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  # ---- /v1/* -> ALB (POST 포함 모든 메서드) ----
  ordered_cache_behavior {
    path_pattern             = "/v1/*"
    target_origin_id         = local.alb_origin_id
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  # ---- /health -> ALB ----
  ordered_cache_behavior {
    path_pattern             = "/health"
    target_origin_id         = local.alb_origin_id
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "${local.prefix}-cdn"
  }
}
