terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
    null    = { source = "hashicorp/null", version = "~> 3.0" }
  }
}

# 3-1 CDN (Lambda@Edge) — us-east-1 (Lambda@Edge 요구)
provider "aws" {
  region = "us-east-1"
}

variable "bibunho" {
  type = string
}

# ── S3 (versioning, BPA, OAC-only) ───────────────────────────────────
resource "aws_s3_bucket" "asset" {
  bucket        = "wsc2026-cdn-asset-${var.bibunho}"
  force_destroy = true
}
resource "aws_s3_bucket_versioning" "asset" {
  bucket = aws_s3_bucket.asset.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_public_access_block" "asset" {
  bucket                  = aws_s3_bucket.asset.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 지급 원본 이미지 업로드 (origin/worldskills_banner.png) — 채점 1-1 / 1-6 (원본 크기 111811)
resource "aws_s3_object" "banner" {
  bucket       = aws_s3_bucket.asset.id
  key          = "origin/worldskills_banner.png"
  source       = "${path.module}/assets/worldskills_banner.png"
  etag         = filemd5("${path.module}/assets/worldskills_banner.png")
  content_type = "image/png"
}

# ── Lambda@Edge resize (python3.12) + Pillow layer ───────────────────
resource "null_resource" "pillow" {
  triggers = { always = "1" }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      d="${path.module}/layer/python"
      rm -rf "${path.module}/layer" && mkdir -p "$d"
      pip3 install --platform manylinux2014_x86_64 --target "$d" --implementation cp --python-version 3.12 --only-binary=:all: Pillow
    EOT
  }
}
data "archive_file" "layer" {
  type        = "zip"
  source_dir  = "${path.module}/layer"
  output_path = "${path.module}/pillow-layer.zip"
  depends_on  = [null_resource.pillow]
}
resource "aws_lambda_layer_version" "pillow" {
  filename            = data.archive_file.layer.output_path
  layer_name          = "wsc2026-pillow"
  compatible_runtimes = ["python3.12"]
}

resource "aws_iam_role" "resize" {
  name = "wsc2026-resize-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"] }
    }]
  })
}
resource "aws_iam_policy" "resize" {
  name = "wsc2026-resize-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "${aws_s3_bucket.asset.arn}/*" },
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:*:*:*" }
    ]
  })
}
resource "aws_iam_role_policy_attachment" "resize" {
  role       = aws_iam_role.resize.name
  policy_arn = aws_iam_policy.resize.arn
}
data "archive_file" "resize" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/resize.zip"
}
resource "aws_lambda_function" "resize" {
  function_name    = "wsc2026-resize"
  role             = aws_iam_role.resize.arn
  handler          = "resize.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.resize.output_path
  source_code_hash = data.archive_file.resize.output_base64sha256
  timeout          = 30
  memory_size      = 512
  layers           = [aws_lambda_layer_version.pillow.arn]
  publish          = true
}

# ── CloudFront ───────────────────────────────────────────────────────
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "wsc2026-cdn-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
resource "aws_cloudfront_function" "device" {
  name    = "wsc2026-device-detect"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = file("${path.module}/functions/device-detect.js")
}
resource "aws_cloudfront_function" "respheader" {
  name    = "wsc2026-response-header"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = file("${path.module}/functions/response-header.js")
}
resource "aws_cloudfront_cache_policy" "main" {
  name        = "wsc2026-cache-policy"
  default_ttl = 86400
  max_ttl     = 31536000
  min_ttl     = 0
  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config {
      query_string_behavior = "all"
    }
    enable_accept_encoding_gzip = true
  }
}
resource "aws_cloudfront_origin_request_policy" "main" {
  name = "wsc2026-origin-policy"
  cookies_config { cookie_behavior = "none" }
  headers_config { header_behavior = "none" }
  query_strings_config { query_string_behavior = "all" }
}
resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  comment             = "wsc2026-cdn"
  default_root_object = "index.html"
  price_class         = "PriceClass_All"

  origin {
    domain_name              = aws_s3_bucket.asset.bucket_regional_domain_name
    origin_id                = "s3-asset"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    target_origin_id         = "s3-asset"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["GET", "HEAD"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = aws_cloudfront_cache_policy.main.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.main.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.device.arn
    }
    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.respheader.arn
    }
    lambda_function_association {
      event_type   = "origin-response"
      lambda_arn   = aws_lambda_function.resize.qualified_arn
      include_body = false
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  viewer_certificate { cloudfront_default_certificate = true }

  tags = { Name = "wsc2026-cdn" }
}

resource "aws_s3_bucket_policy" "oac" {
  bucket = aws_s3_bucket.asset.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.asset.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.main.arn } }
    }]
  })
}

output "cdn_domain" { value = aws_cloudfront_distribution.main.domain_name }
output "asset_bucket" { value = aws_s3_bucket.asset.id }
