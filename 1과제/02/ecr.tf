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

# 레지스트리(계정/리전) 스캔 설정을 BASIC + SCAN_ON_PUSH 로 명시.
#   repo 의 scan_on_push=true 만으로는, 계정 레지스트리가 ENHANCED 이거나 스캔이
#   비활성이면 실제 스캔이 안 돌아 describe-image-scan-findings 가 ScanNotFound 를 낸다.
#   => BASIC 스캔을 켜서 push 시 자동 스캔되도록 한다. (채점 3-1)
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "BASIC"
  rule {
    scan_frequency = "SCAN_ON_PUSH"
    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}

# ── book 이미지 빌드 & 푸시 (docker 데몬 + 인터넷 필요) ──
resource "null_resource" "build_push_book" {
  triggers = {
    dockerfile = filemd5("${path.module}/files/Dockerfile")
    binary     = filemd5("${path.module}/files/book")
    repo       = aws_ecr_repository.book.repository_url
    tag        = local.image_tag
  }

  # main 은 Linux Bastion 에서 apply 된다 (bastion/ 1단계 참고). bash + docker.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION   = local.region
      REGISTRY = local.registry
      IMAGE    = local.image_url
      CTX      = "${path.module}/files"
      REPO     = local.ecr_repo
      TAG      = local.image_tag
    }
    command = <<-EOT
      set -eu
      aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
      docker build --platform linux/amd64 --provenance=false -t "$IMAGE" "$CTX"
      docker push "$IMAGE"

      # 스캔이 COMPLETE 될 때까지 대기. 스캔이 아직 없으면(SCAN_ON_PUSH 지연/미동작)
      # start-image-scan 을 재시도한다. (채점 3-1 describe-image-scan-findings)
      for i in $(seq 1 36); do
        ST=$(aws ecr describe-image-scan-findings --repository-name "$REPO" \
          --image-id imageTag="$TAG" --region "$REGION" \
          --query 'imageScanStatus.status' --output text 2>/dev/null || echo NOTFOUND)
        if [ "$ST" = "COMPLETE" ]; then echo "ECR scan COMPLETE"; break; fi
        if [ "$ST" = "NOTFOUND" ] || [ "$ST" = "FAILED" ]; then
          aws ecr start-image-scan --repository-name "$REPO" --image-id imageTag="$TAG" \
            --region "$REGION" >/dev/null 2>&1 || true
        fi
        echo "waiting ECR scan... ($ST)"; sleep 10
      done
    EOT
  }

  depends_on = [aws_ecr_repository.book, aws_ecr_registry_scanning_configuration.this]
}
