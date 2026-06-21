# =============================================================================
# Module 2. CDN (S3 + CloudFront + OAC + CloudFront Function)  |  Region: us-east-1
#  - 버킷 cdn-static-<비번호> (퍼블릭 차단), index.html/style.css/image.png 업로드
#  - OAC cdn-oac, CloudFront Distribution(comment cdn-<비번호>, root index.html)
#  - CloudFront Function cdn-add-security-header (viewer-response, x-custom-header:wsc2026)
#  - S3 직접 접근 차단 (OAC + 버킷 정책)
# =============================================================================

locals {
  cdn_bucket = "cdn-static-${var.team_id}"
  cdn_files = {
    "index.html" = "text/html"
    "style.css"  = "text/css"
    "image.png"  = "image/png"
  }
}

resource "aws_s3_bucket" "cdn" {
  provider      = aws.use1
  bucket        = local.cdn_bucket
  force_destroy = true

  tags = {
    Module = "CDN"
  }
}

resource "aws_s3_bucket_public_access_block" "cdn" {
  provider                = aws.use1
  bucket                  = aws_s3_bucket.cdn.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "cdn" {
  provider     = aws.use1
  for_each     = local.cdn_files
  bucket       = aws_s3_bucket.cdn.id
  key          = each.key
  source       = "${path.module}/files/cdn/${each.key}"
  etag         = filemd5("${path.module}/files/cdn/${each.key}")
  content_type = each.value
}

# ---- OAC ----
resource "aws_cloudfront_origin_access_control" "cdn" {
  provider                          = aws.use1
  name                              = "cdn-oac"
  description                       = "WSC 2026 OAC"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ---- CloudFront Function (viewer-response 헤더 추가) ----
resource "aws_cloudfront_function" "security_header" {
  provider = aws.use1
  name     = "cdn-add-security-header"
  runtime  = "cloudfront-js-2.0"
  comment  = "Add WSC custom response header"
  publish  = true
  code     = file("${path.module}/files/cdn/cdn-add-security-header.js")
}

# ---- Distribution ----
resource "aws_cloudfront_distribution" "cdn" {
  provider            = aws.use1
  enabled             = true
  comment             = "cdn-${var.team_id}"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  http_version        = "http2"
  is_ipv6_enabled     = true

  origin {
    origin_id                = "${local.cdn_bucket}-origin"
    domain_name              = aws_s3_bucket.cdn.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.cdn.id
  }

  default_cache_behavior {
    target_origin_id       = "${local.cdn_bucket}-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # AWS 관리형 CachePolicy: CachingOptimized
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.security_header.arn
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

  tags = {
    Module = "CDN"
  }
}

# ---- S3 버킷 정책 (CloudFront OAC 경유만 허용) ----
data "aws_iam_policy_document" "cdn_bucket" {
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.cdn.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.cdn.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "cdn" {
  provider   = aws.use1
  bucket     = aws_s3_bucket.cdn.id
  policy     = data.aws_iam_policy_document.cdn_bucket.json
  depends_on = [aws_s3_bucket_public_access_block.cdn]
}
