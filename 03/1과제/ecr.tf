# ═══════════════════════════════════════════════════════════════
# ECR  (과제 6)
#   - Repo: wsc2026-book-ecr / Private
#   - scanOnPush = true (취약점 0 이어야 함 -> scratch 이미지)
#   - 같은 태그 덮어쓰기 허용하되 v1* 태그는 예외(불변)
#       => imageTagMutability = MUTABLE_WITH_EXCLUSION + filter v1*
#   - CMK(wsc2026-ecr-kms) 암호화
#   - book 이미지를 v1.0.0 으로 빌드/푸시
#
# 채점 3-1: True MUTABLE_WITH_EXCLUSION v1* KMS / v1.0.0
# ═══════════════════════════════════════════════════════════════

resource "aws_ecr_repository" "book" {
  name                 = local.ecr_repo
  image_tag_mutability = "MUTABLE_WITH_EXCLUSION"
  force_delete         = true

  image_tag_mutability_exclusion_filter {
    filter      = "v1*"
    filter_type = "WILDCARD"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = { Name = local.ecr_repo }
}

# ── book 이미지 빌드 & 푸시 (v1.0.0) ──────────────────────────
# 전제: docker 데몬 실행 중 + 인터넷(빌드 단계에서 static curl/upx 다운로드).
resource "null_resource" "build_push_book" {
  triggers = {
    dockerfile = filemd5("${path.module}/files/Dockerfile")
    binary     = filemd5("${path.module}/files/book")
    repo       = aws_ecr_repository.book.repository_url
  }

  provisioner "local-exec" {
    interpreter = ["powershell", "-NoProfile", "-Command"]
    environment = {
      REGION   = local.region
      REGISTRY = local.registry
      IMAGE    = local.image_url
      CTX      = "${path.module}/files"
    }
    command = <<-EOT
      $ErrorActionPreference = 'Stop'
      $pw = (aws ecr get-login-password --region $env:REGION) | Out-String
      docker login --username AWS --password $pw.Trim() $env:REGISTRY
      if ($LASTEXITCODE -ne 0) { throw "docker login failed" }
      docker build --platform linux/amd64 --provenance=false -t $env:IMAGE $env:CTX
      if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
      docker push $env:IMAGE
      if ($LASTEXITCODE -ne 0) { throw "docker push failed" }
    EOT
  }

  depends_on = [aws_ecr_repository.book]
}
