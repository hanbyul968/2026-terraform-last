# ---------------------------------------------------------------------------
# 아티팩트 스테이징: color 바이너리(7.78MB)는 user-data(16KB 한도)에 넣을 수 없으므로
# S3 에 업로드하고 부팅 시 인스턴스가 내려받는다. 다운로드는 S3 게이트웨이 엔드포인트로
# 사설/무료 처리(vpc.tf). apply 시 바이너리가 함께 올라가므로 다른 계정/날짜에서도 자립.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.name}-artifacts"
  force_destroy = true
  tags          = { Name = "${local.name}-artifacts" }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# color 실행 바이너리 업로드. source_hash 로 변경 시 자동 재업로드 + 롤링 교체 트리거.
resource "aws_s3_object" "color" {
  bucket      = aws_s3_bucket.artifacts.id
  key         = "color"
  source      = "${path.module}/../app/color/color"
  source_hash = filemd5("${path.module}/../app/color/color")
}
