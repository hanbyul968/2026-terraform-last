# Seed 덤프를 S3 에 올리고, db-init Job 의 initContainer 가 받아서 스트리밍 적재한다.
# ConfigMap(1MB 한도) 대신 S3 라서 100만 줄(수십 MB) 덤프도 OK. 작은 덤프도 동일하게 동작.

# 시드/아티팩트 전용 비공개 버킷 (random_id.bucket 은 s3.tf 에서 정의됨, 재사용)
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${local.name}-artifacts-${random_id.bucket.hex}"
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

# 덤프 업로드 (대회날 ../load_user.dump 만 바꿔서 apply 하면 새 덤프로 교체됨)
resource "aws_s3_object" "seed" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "seed/load_user.dump"
  source = "${path.module}/../load_user.dump"
  etag   = filemd5("${path.module}/../load_user.dump")
}

# db-init Job 이 S3 에서 시드를 받을 수 있게 IRSA 역할 (해당 객체 GetObject 만)
data "aws_iam_policy_document" "dbinit_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = ["system:serviceaccount:${kubernetes_namespace.app.metadata[0].name}:db-init"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dbinit" {
  name               = "${local.name}-db-init"
  assume_role_policy = data.aws_iam_policy_document.dbinit_assume.json
}

resource "aws_iam_role_policy" "dbinit" {
  name = "s3-seed-read"
  role = aws_iam_role.dbinit.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["${aws_s3_bucket.artifacts.arn}/*"]
    }]
  })
}

resource "kubernetes_service_account" "db_init" {
  metadata {
    name      = "db-init"
    namespace = kubernetes_namespace.app.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.dbinit.arn
    }
  }
}
