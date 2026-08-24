# CloudFront: single endpoint. /images/* → S3, default → ALB.
# Caches GET responses (product GET by id is repeated — huge cost+latency win).

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${local.name}-s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront Function: rewrite <images_prefix>/foo.jpg → /foo.jpg so S3 key matches.
# prefix 가 바뀌면 var.images_prefix 만 수정 (함수/캐시 동작 모두 자동 반영).
resource "aws_cloudfront_function" "strip_images_prefix" {
  name    = "${local.name}-strip-images"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOT
    var PREFIX = '${var.images_prefix}/';
    function handler(event) {
      var req = event.request;
      if (req.uri.indexOf(PREFIX) === 0) {
        req.uri = req.uri.substring(PREFIX.length - 1); // strip prefix, keep leading '/'
      }
      return req;
    }
  EOT
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "${local.name} single endpoint"
  http_version    = "http2and3"
  price_class     = "PriceClass_200"
  web_acl_id      = aws_wafv2_web_acl.cloudfront.arn

  origin {
    domain_name              = aws_s3_bucket.images.bucket_regional_domain_name
    origin_id                = "s3-images"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  origin {
    domain_name = aws_lb.this.dns_name
    origin_id   = "alb"
    # Secret header so WAF can tell CloudFront traffic from direct ALB hits.
    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify.result
    }
    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 60
      origin_read_timeout      = 30
    }
  }

  # Default: pass through to ALB. No caching for POST/PUT.
  # GETs cached selectively per-path (product GET below).
  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = "allow-all"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  # 캐시 대상 앱마다 동작을 생성한다 (apps.tf 의 cache_ttl > 0).
  # 이전에는 product 경로가 하드코딩되어 있었다. 지금은 tfvars 에서
  # apps = { <앱> = { cache_ttl = 10, cache_query_keys = ["id"] } } 만 주면 된다.
  # 조회형 API 캐시는 오리진 부하와 응답시간을 동시에 줄여 성능/비용에 함께 기여한다.
  dynamic "ordered_cache_behavior" {
    for_each = local.cached_apps
    content {
      path_pattern           = "${ordered_cache_behavior.value.path}*"
      target_origin_id       = "alb"
      viewer_protocol_policy = "allow-all"
      allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods         = ["GET", "HEAD"]
      compress               = true

      cache_policy_id          = aws_cloudfront_cache_policy.app_get[ordered_cache_behavior.key].id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    }
  }

  # <images_prefix>/* → S3
  ordered_cache_behavior {
    path_pattern           = "${var.images_prefix}/*"
    target_origin_id       = "s3-images"
    viewer_protocol_policy = "allow-all"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id = aws_cloudfront_cache_policy.images.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.strip_images_prefix.arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

# /images/* 전용: 쿼리스트링을 캐시 키에 포함 → ?v=1 / ?v=2 등 다른 쿼리는 다르게 캐싱.
# (이미지가 새로 올라가며 쿼리스트링으로 캐시 무력화돼도 항상 최신을 가져옴)
# 같은 URL+같은 쿼리는 여전히 캐시 히트(default_ttl 1일)라 성능도 유지.
resource "aws_cloudfront_cache_policy" "images" {
  name        = "${local.name}-images"
  min_ttl     = 0
  default_ttl = 86400
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config { query_string_behavior = "all" }
  }
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

# 캐시 정책 — 캐시 대상 앱마다 생성. 캐시 키에 포함할 쿼리 파라미터는 앱별 지정.
# cache_query_keys 가 비어 있으면 쿼리스트링을 캐시 키에서 제외한다(경로만으로 캐싱).
resource "aws_cloudfront_cache_policy" "app_get" {
  for_each = local.cached_apps

  name        = "${local.name}-${each.key}-get"
  min_ttl     = 0
  default_ttl = each.value.cache_ttl
  max_ttl     = max(each.value.cache_ttl * 6, each.value.cache_ttl)

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config {
      query_string_behavior = length(each.value.cache_query_keys) > 0 ? "whitelist" : "none"
      dynamic "query_strings" {
        for_each = length(each.value.cache_query_keys) > 0 ? [1] : []
        content { items = each.value.cache_query_keys }
      }
    }
  }
}
