# ═══════════════════════════════════════════════════════════════
# S3 + 정적 객체  (과제 4)
#   - Bucket: wskorea26-concert-bucket-<비번호>
#   - 객체 경로: /web/main/index.html, /web/main/main.jpeg
#   - 모든 객체 KMS(wskorea26-s3-key) 암호화
#   - 퍼블릭 접근 전면 차단, CloudFront(OAC) 로만 GetObject
# 채점 2-1: 객체 키 web/main/index.html, web/main/main.jpeg
# 채점 2-2: 객체 SSE-KMS = alias/wskorea26-s3-key, PublicAccessBlock 4개 True, IsPublic False
# ═══════════════════════════════════════════════════════════════

resource "aws_s3_bucket" "this" {
  bucket = local.bucket_name
  tags   = { Name = local.bucket_name }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.this.id
  key          = "web/main/index.html"
  source       = "${path.module}/files/index.html"
  source_hash  = filemd5("${path.module}/files/index.html")
  content_type = "text/html"
  kms_key_id   = aws_kms_key.s3.arn
}

resource "aws_s3_object" "main" {
  bucket       = aws_s3_bucket.this.id
  key          = "web/main/main.jpeg"
  source       = "${path.module}/files/main.jpeg"
  source_hash  = filemd5("${path.module}/files/main.jpeg")
  content_type = "image/jpeg"
  kms_key_id   = aws_kms_key.s3.arn
}

# CloudFront OAC 만 읽기 허용
resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.this.arn}/*"
      Condition = {
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.this.arn }
      }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.this]
}
