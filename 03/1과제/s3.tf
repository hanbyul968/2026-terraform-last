# ═══════════════════════════════════════════════════════════════
# S3  (과제 9)
#   - Bucket: wsc2026-static-<영문4>-<비번호>-bucket
#   - 배포 정적 파일을 static/ 에 업로드 (static/index.html, static/main.jpeg)
#   - Private + CloudFront(OAC) 에서만 접근
#   - 버킷/객체 SSE-KMS(wsc2026-bucket-kms) + 버킷 키 활성화
#
# 채점 6-1: PublicAccessBlock 4개 True / aws:kms True / 객체 KMS PASS
# ═══════════════════════════════════════════════════════════════

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
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.bucket.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.static.id
  key          = "static/index.html"
  source       = "${path.module}/files/index.html"
  etag         = filemd5("${path.module}/files/index.html")
  content_type = "text/html"
  kms_key_id   = aws_kms_key.bucket.arn
  depends_on   = [aws_s3_bucket_server_side_encryption_configuration.static]
}

resource "aws_s3_object" "main" {
  bucket       = aws_s3_bucket.static.id
  key          = "static/main.jpeg"
  source       = "${path.module}/files/main.jpeg"
  etag         = filemd5("${path.module}/files/main.jpeg")
  content_type = "image/jpeg"
  kms_key_id   = aws_kms_key.bucket.arn
  depends_on   = [aws_s3_bucket_server_side_encryption_configuration.static]
}

# CloudFront OAC 읽기 허용
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
        StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.this.arn }
      }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.static]
}
