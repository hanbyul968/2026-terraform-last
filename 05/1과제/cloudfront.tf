############################
# CloudFront OAC for S3
############################

resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "gj2026-s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

############################
# CloudFront VPC Origin for ALB
############################

resource "aws_cloudfront_vpc_origin" "alb" {
  vpc_origin_endpoint_config {
    name                   = "gj2026-alb-origin"
    arn                    = aws_lb.alb.arn
    http_port              = 80
    https_port             = 443
    origin_protocol_policy = "http-only"
    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }
}

############################
# CloudFront Distribution
############################

resource "aws_cloudfront_distribution" "cdn" {
  comment             = "gj2026-cdn"
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_All"
  web_acl_id          = aws_wafv2_web_acl.acl.arn

  # S3 Origin
  origin {
    domain_name              = aws_s3_bucket.static.bucket_regional_domain_name
    origin_id                = "s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  # ALB VPC Origin
  origin {
    domain_name = aws_lb.alb.dns_name
    origin_id   = "alb"
    vpc_origin_config {
      vpc_origin_id              = aws_cloudfront_vpc_origin.alb.id
      origin_read_timeout        = 30
      origin_keepalive_timeout   = 5
    }
  }

  # Lambda Function URL Origin
  origin {
    domain_name = replace(replace(aws_lambda_function_url.reservation.function_url, "https://", ""), "/", "")
    origin_id   = "lambda"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  # Default: S3 (static content, cached)
  default_cache_behavior {
    target_origin_id       = "s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    compress               = true
  }

  # /v1* -> ALB (no cache, forward all query strings)
  ordered_cache_behavior {
    path_pattern           = "/v1*"
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3" # AllViewer
  }

  # /grafana* -> ALB (no cache)
  ordered_cache_behavior {
    path_pattern           = "/grafana*"
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  }

  # /reservation* -> Lambda (no cache, forward query strings)
  ordered_cache_behavior {
    path_pattern           = "/reservation*"
    target_origin_id       = "lambda"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "gj2026-cdn" }
}
