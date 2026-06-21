# =============================================================================
# 4. 정적 웹 호스팅 (S3)
#  - 버킷명: <id>-static-site
#  - index.html, main.jpeg 업로드
#  - 퍼블릭 접근 차단(Block Public Access) + CloudFront OAC를 통해서만 접근
# =============================================================================

resource "aws_s3_bucket" "static" {
  bucket        = local.bucket_name
  force_destroy = true

  tags = {
    Name = local.bucket_name
  }
}

# 퍼블릭 접근 전면 차단 (채점 2-2: BlockPublicAcls=True)
resource "aws_s3_bucket_public_access_block" "static" {
  bucket                  = aws_s3_bucket.static.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "static" {
  bucket = aws_s3_bucket.static.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ---- 정적 파일 업로드 ----
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.static.id
  key          = "index.html"
  source       = "${path.module}/static/index.html"
  etag         = filemd5("${path.module}/static/index.html")
  content_type = "text/html"
}

resource "aws_s3_object" "main_jpeg" {
  bucket       = aws_s3_bucket.static.id
  key          = "main.jpeg"
  source       = "${path.module}/static/main.jpeg"
  etag         = filemd5("${path.module}/static/main.jpeg")
  content_type = "image/jpeg"
}

# CloudFront -> S3 접근만 허용하는 버킷 정책
data "aws_iam_policy_document" "s3_cloudfront" {
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.static.arn}/*"]

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

resource "aws_s3_bucket_policy" "static" {
  bucket = aws_s3_bucket.static.id
  policy = data.aws_iam_policy_document.s3_cloudfront.json

  depends_on = [aws_s3_bucket_public_access_block.static]
}
