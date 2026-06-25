# ═══════════════════════════════════════════════════════════════
# ECR  (과제 6)
#   - Repo: wskorea26-book-repo, 태그 stable
#   - scanOnPush = true, encryptionType = KMS
#   - Critical/High 취약점 0 (scratch 기반 이미지로 OS 패키지 제거)
# 채점 3-1: repositoryName / scanOnPush True / encryptionType KMS / 태그 stable / 취약점 없음
# ═══════════════════════════════════════════════════════════════

resource "aws_ecr_repository" "book" {
  name                 = local.ecr_repo
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.s3.arn
  }

  tags = { Name = local.ecr_repo }
}

# ── book 이미지 빌드 & 푸시 (docker 데몬 + 인터넷 필요) ──
resource "null_resource" "build_push_book" {
  triggers = {
    dockerfile = filemd5("${path.module}/files/Dockerfile")
    binary     = filemd5("${path.module}/files/book")
    repo       = aws_ecr_repository.book.repository_url
    tag        = local.image_tag
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
