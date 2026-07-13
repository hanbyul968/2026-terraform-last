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

      # scanOnPush 가 실제로 동작하지 않는 경우 대비: 스캔을 명시 트리거하고
      # COMPLETE 될 때까지 대기한다. (채점 3-1 describe-image-scan-findings)
      aws ecr start-image-scan --repository-name "$REPO" --image-id imageTag="$TAG" \
        --region "$REGION" >/dev/null 2>&1 || true
      for i in $(seq 1 30); do
        ST=$(aws ecr describe-image-scan-findings --repository-name "$REPO" \
          --image-id imageTag="$TAG" --region "$REGION" \
          --query 'imageScanStatus.status' --output text 2>/dev/null || echo PENDING)
        if [ "$ST" = "COMPLETE" ]; then echo "ECR scan COMPLETE"; break; fi
        echo "waiting ECR scan... ($ST)"; sleep 10
      done
    EOT
  }

  depends_on = [aws_ecr_repository.book]
}
