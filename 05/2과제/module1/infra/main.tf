terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "gj2026-cdn-bucket-${var.pin}"
}

# ─────────────────────────────────────────────
# S3 Bucket (퍼블릭 접근 차단)
# ─────────────────────────────────────────────
resource "aws_s3_bucket" "cdn" {
  bucket        = local.bucket_name
  force_destroy = true
  tags          = { Name = local.bucket_name }
}

resource "aws_s3_bucket_public_access_block" "cdn" {
  bucket                  = aws_s3_bucket.cdn.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 배포파일 dog.png 자동 업로드 (images/ prefix)
resource "aws_s3_object" "dog" {
  bucket       = aws_s3_bucket.cdn.id
  key          = "images/dog.png"
  source       = "${path.module}/../../files/dog.png"
  etag         = filemd5("${path.module}/../../files/dog.png")
  content_type = "image/png"
}

# CloudFront OAC (S3 직접 접근 차단, CloudFront 경유만 허용)
resource "aws_cloudfront_origin_access_control" "cdn" {
  name                              = "gj2026-cdn-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_s3_bucket_policy" "cdn" {
  bucket = aws_s3_bucket.cdn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.cdn.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
        }
      }
    }]
  })
  depends_on = [aws_cloudfront_distribution.cdn]
}

# ─────────────────────────────────────────────
# Lambda IAM Role (rotate + Lambda@Edge 공용)
# ─────────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "gj2026-cdn-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["lambda.amazonaws.com", "edgelambda.amazonaws.com"] }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_s3" {
  name = "gj2026-cdn-s3"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.cdn.arn}/*"
    }]
  })
}

# ─────────────────────────────────────────────
# Lambda: gj2026-cdn-rotate (Origin 함수)
# Pillow 패키지를 apply 시점에 자동 빌드 (CloudShell/Linux 기준)
# ─────────────────────────────────────────────
resource "null_resource" "pillow_build" {
  triggers = {
    rotate_py = filemd5("${path.module}/lambda/rotate.py")
  }
  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "bash ${path.module}/build.sh"
  }
}

# null_resource에 depends_on → archive를 apply 시점에 읽음 (빌드 후)
data "archive_file" "rotate" {
  type        = "zip"
  output_path = "${path.module}/lambda/rotate.zip"
  source_dir  = "${path.module}/lambda/rotate_pkg"
  depends_on  = [null_resource.pillow_build]
}

resource "aws_lambda_function" "rotate" {
  function_name    = "gj2026-cdn-rotate"
  role             = aws_iam_role.lambda.arn
  handler          = "rotate.lambda_handler"
  runtime          = "python3.12" # PDF 명세: python3.14 → AWS 지원 시 변경
  filename         = data.archive_file.rotate.output_path
  source_code_hash = data.archive_file.rotate.output_base64sha256
  timeout          = 30
  memory_size      = 512

  environment {
    variables = {
      BUCKET_NAME = local.bucket_name
    }
  }

  tags = { Name = "gj2026-cdn-rotate" }
}

resource "aws_lambda_function_url" "rotate" {
  function_name      = aws_lambda_function.rotate.function_name
  authorization_type = "NONE"
}

# ─────────────────────────────────────────────
# Lambda@Edge: gj2026-cdn-request (viewer-request)
# ─────────────────────────────────────────────
data "archive_file" "request" {
  type        = "zip"
  output_path = "${path.module}/lambda/request.zip"
  source {
    content  = file("${path.module}/lambda/request.py")
    filename = "request.py"
  }
}

resource "aws_lambda_function" "request" {
  function_name    = "gj2026-cdn-request"
  role             = aws_iam_role.lambda.arn
  handler          = "request.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.request.output_path
  source_code_hash = data.archive_file.request.output_base64sha256
  publish          = true # Lambda@Edge는 publish 필수
  timeout          = 5

  tags = { Name = "gj2026-cdn-request" }
}

# ─────────────────────────────────────────────
# Lambda@Edge: gj2026-cdn-response (origin-response)
# ─────────────────────────────────────────────
data "archive_file" "response" {
  type        = "zip"
  output_path = "${path.module}/lambda/response.zip"
  source {
    content  = file("${path.module}/lambda/response.py")
    filename = "response.py"
  }
}

resource "aws_lambda_function" "response" {
  function_name    = "gj2026-cdn-response"
  role             = aws_iam_role.lambda.arn
  handler          = "response.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.response.output_path
  source_code_hash = data.archive_file.response.output_base64sha256
  publish          = true
  timeout          = 5

  tags = { Name = "gj2026-cdn-response" }
}

# ─────────────────────────────────────────────
# CloudFront Cache Policy (image + rotate 쿼리 기준 캐시 분리)
# ─────────────────────────────────────────────
resource "aws_cloudfront_cache_policy" "cdn" {
  name        = "gj2026-cdn-cache-policy"
  min_ttl     = 0
  default_ttl = 86400
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config { cookie_behavior = "none" }
    headers_config { header_behavior = "none" }
    query_strings_config {
      query_string_behavior = "whitelist"
      query_strings {
        items = ["image", "rotate"]
      }
    }
  }
}

# ─────────────────────────────────────────────
# CloudFront Distribution
# ─────────────────────────────────────────────
locals {
  rotate_domain = replace(replace(aws_lambda_function_url.rotate.function_url, "https://", ""), "/", "")
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled = true
  comment = "gj2026-cdn"

  origin {
    domain_name = local.rotate_domain
    origin_id   = "lambda-rotate"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "lambda-rotate"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.cdn.id
    compress               = true
  }

  # /images behavior: Lambda@Edge 연결
  ordered_cache_behavior {
    path_pattern           = "/images"
    target_origin_id       = "lambda-rotate"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = aws_cloudfront_cache_policy.cdn.id
    compress               = true

    lambda_function_association {
      event_type   = "viewer-request"
      lambda_arn   = aws_lambda_function.request.qualified_arn
      include_body = false
    }

    lambda_function_association {
      event_type   = "origin-response"
      lambda_arn   = aws_lambda_function.response.qualified_arn
      include_body = false
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "gj2026-cdn" }
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "rotate_function_url" {
  value = aws_lambda_function_url.rotate.function_url
}

output "s3_bucket_name" {
  value = aws_s3_bucket.cdn.bucket
}
