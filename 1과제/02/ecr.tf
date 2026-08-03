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
    scan_logic = "v3-empty-map-and-severity-check"
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

      # scanOnPush가 늦게 시작될 수 있으므로 상태를 확인하며 명시적 시작도 재시도한다.
      # COMPLETE가 아니면 apply를 실패시켜 채점 시 빈 출력으로 넘어가지 않게 한다.
      SCAN_STATUS="NOTFOUND"
      for i in $(seq 1 60); do
        SCAN_STATUS=$(aws ecr describe-image-scan-findings --repository-name "$REPO" \
          --image-id imageTag="$TAG" --region "$REGION" \
          --query 'imageScanStatus.status' --output text 2>/dev/null || true)
        [ -n "$SCAN_STATUS" ] || SCAN_STATUS="NOTFOUND"

        if [ "$SCAN_STATUS" = "COMPLETE" ]; then
          COUNTS=$(aws ecr describe-image-scan-findings --repository-name "$REPO" \
            --image-id imageTag="$TAG" --region "$REGION" \
            --query 'imageScanFindings.findingSeverityCounts' --output json)
          # AWS CLI는 빈 map({})을 JMESPath로 직접 조회하면 출력하지 않을 수 있다.
          [ -n "$COUNTS" ] || COUNTS='{}'

          CRITICAL=$(aws ecr describe-image-scan-findings --repository-name "$REPO" \
            --image-id imageTag="$TAG" --region "$REGION" \
            --query 'imageScanFindings.findingSeverityCounts.CRITICAL || `0`' --output text)
          HIGH=$(aws ecr describe-image-scan-findings --repository-name "$REPO" \
            --image-id imageTag="$TAG" --region "$REGION" \
            --query 'imageScanFindings.findingSeverityCounts.HIGH || `0`' --output text)

          echo "ECR scan COMPLETE - findingSeverityCounts:"
          echo "$COUNTS"
          # findingSeverityCounts 가 비어 있으면({}) CRITICAL/HIGH 가 0 이라는 뜻이므로
          # 통과시킨다. (채점 기준: Critical/High 취약점이 없으면 정답. LOW/MEDIUM 무관)
          if [ "$CRITICAL" != "0" ] || [ "$HIGH" != "0" ]; then
            echo "ECR scan rejected: CRITICAL=$CRITICAL, HIGH=$HIGH" >&2
            exit 1
          fi
          echo "ECR scan accepted: CRITICAL=0, HIGH=0"
          exit 0
        fi

        case "$SCAN_STATUS" in
          FAILED|UNSUPPORTED_IMAGE|SCAN_ELIGIBILITY_EXPIRED|FINDINGS_UNAVAILABLE|LIMIT_EXCEEDED)
            echo "ECR scan failed with terminal status: $SCAN_STATUS" >&2
            exit 1
            ;;
          NOTFOUND|None)
            aws ecr start-image-scan --repository-name "$REPO" --image-id imageTag="$TAG" \
              --region "$REGION" >/dev/null 2>&1 || true
            ;;
        esac

        echo "waiting ECR scan... ($SCAN_STATUS, $i/60)"
        sleep 10
      done

      echo "ECR scan did not complete within 10 minutes (last status: $SCAN_STATUS)" >&2
      exit 1
    EOT
  }

  depends_on = [aws_ecr_repository.book, aws_ecr_registry_scanning_configuration.this]
}
