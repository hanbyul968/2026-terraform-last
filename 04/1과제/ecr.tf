# ═══════════════════════════════════════════════════════════════
# ECR  (과제 7)
#   - Repo: wsc-repo, tag v1.0.0
#   - 채점 5-1-A: imageTagMutability=MUTABLE, scanOnPush=true, encryptionType=KMS
#   - 채점 5-2-A: 이미지 크기 8MB 이하
#   - 채점 5-2-B: 스캔 COMPLETE, 취약점 0
#   - 컨테이너 안에서 curl 실행 가능해야 함 (채점 6-5)
#   => scratch + UPX 압축 book + static curl  (OS 패키지 0 => 취약점 0)
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
    kms_key         = aws_kms_key.main.arn
  }

  tags = { Name = local.ecr_repo }
}

# workload 노드는 NAT 가 없어 public.ecr.aws 에 직접 접근 불가.
# addon 이미지(LB controller, fluent-bit, prometheus, grafana, exporters)는
# pull-through cache 를 통해 <acct>.dkr.ecr.<region>.amazonaws.com/ecr-public/... 로 받는다.
resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  ecr_repository_prefix = "ecr-public"
  upstream_registry_url = "public.ecr.aws"
}

resource "aws_ecr_pull_through_cache_rule" "quay" {
  ecr_repository_prefix = "quay"
  upstream_registry_url = "quay.io"
}

# ── book 이미지 빌드 & 푸시 ────────────────────────────────────
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
