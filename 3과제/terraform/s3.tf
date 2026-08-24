resource "aws_s3_bucket" "images" {
  bucket        = "${local.bucket_prefix}-images"
  force_destroy = true
  tags          = { Name = "${local.bucket_prefix}-images" }
}

resource "aws_s3_bucket_public_access_block" "images" {
  bucket                  = aws_s3_bucket.images.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "images" {
  bucket = aws_s3_bucket.images.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "images" {
  bucket = aws_s3_bucket.images.id
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_cors_configuration" "images" {
  bucket = aws_s3_bucket.images.id
  cors_rule {
    allowed_methods = ["GET", "PUT", "POST"]
    allowed_origins = ["*"]
    allowed_headers = ["*"]
    max_age_seconds = 3000
  }
}

# Bucket policy: allow CloudFront OAC + the product app IRSA role to read/write
data "aws_iam_policy_document" "images" {
  statement {
    sid       = "AllowCloudFrontReadViaOAC"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.images.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
  # S3 쓰기가 필요한 모든 앱의 IRSA 역할에 권한을 준다 (앱 이름 하드코딩 제거).
  # needs_s3 인 앱이 없으면 이 statement 는 생성되지 않는다.
  dynamic "statement" {
    for_each = length(local.s3_apps) > 0 ? [1] : []
    content {
      sid       = "AllowAppWrite"
      actions   = ["s3:PutObject", "s3:PutObjectAcl", "s3:GetObject", "s3:DeleteObject"]
      resources = ["${aws_s3_bucket.images.arn}/*"]
      principals {
        type        = "AWS"
        identifiers = [for n, _ in local.s3_apps : aws_iam_role.app_s3[n].arn]
      }
    }
  }
}

resource "aws_s3_bucket_policy" "images" {
  bucket = aws_s3_bucket.images.id
  policy = data.aws_iam_policy_document.images.json
}
