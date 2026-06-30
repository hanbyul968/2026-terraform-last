############################
# S3 bucket (private, DSSE-KMS, bucket key, block SSE-C)
############################
resource "aws_s3_bucket" "static" {
  bucket = local.bucket_name
  tags   = { Name = local.bucket_name }
}

resource "aws_s3_bucket_public_access_block" "static" {
  bucket                  = aws_s3_bucket.static.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "static" {
  bucket = aws_s3_bucket.static.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms:dsse"
      kms_master_key_id = data.aws_kms_key.main.arn
    }
    bucket_key_enabled       = true
    blocked_encryption_types = ["SSE-C"]
  }
}

############################
# Static objects
############################
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.static.id
  key          = "index.html"
  source       = "${path.module}/files/index.html"
  etag         = filemd5("${path.module}/files/index.html")
  content_type = "text/html"
}

resource "aws_s3_object" "main" {
  bucket       = aws_s3_bucket.static.id
  key          = "main.jpeg"
  source       = "${path.module}/files/main.jpeg"
  etag         = filemd5("${path.module}/files/main.jpeg")
  content_type = "image/jpeg"
}

############################
# CloudFront OAC + Function + Distribution
############################
resource "aws_cloudfront_origin_access_control" "static" {
  name                              = "wsc-2026-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "rewrite" {
  name    = "wsc-2026-functions"
  runtime = "cloudfront-js-2.0"
  comment = "/index -> index.html, /main -> main.jpeg"
  publish = true
  code    = file("${path.module}/files/cf-function.js")
}

resource "aws_cloudfront_distribution" "static" {
  enabled             = true
  comment             = "wsc-2026-cloud-front"
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.static.bucket_regional_domain_name
    origin_id                = "s3-static"
    origin_access_control_id = aws_cloudfront_origin_access_control.static.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-static"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.rewrite.arn
    }

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "wsc-2026-cloud-front" }
}

############################
# Bucket policy: allow CloudFront OAC read
############################
resource "aws_s3_bucket_policy" "static" {
  bucket = aws_s3_bucket.static.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.static.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.static.arn
        }
      }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.static]
}
