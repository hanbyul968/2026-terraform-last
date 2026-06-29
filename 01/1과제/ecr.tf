############################
# ECR repository (private, KMS, IMMUTABLE, scan on push)
############################
resource "aws_ecr_repository" "book" {
  name                 = local.ecr_repo
  image_tag_mutability = "IMMUTABLE"
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

############################
# Build & push book image (scratch image, tag latest)
#   전제: docker, aws CLI 가 PATH 에 있고 docker 데몬 실행 중.
#   PowerShell 파이프 인코딩 이슈 회피를 위해 토큰을 --password 로 전달.
############################
resource "null_resource" "build_push_book" {
  triggers = {
    dockerfile = filemd5("${path.module}/files/Dockerfile")
    binary     = filemd5("${path.module}/files/book")
    repo       = aws_ecr_repository.book.repository_url
  }

  # main 은 Linux Bastion 에서 apply 된다 (bastion/ 1단계 참고). bash + docker.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION   = local.region
      REGISTRY = local.registry
      IMAGE    = "${aws_ecr_repository.book.repository_url}:latest"
      CTX      = "${path.module}/files"
    }
    command = <<-EOT
      set -euo pipefail
      aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"
      docker build --platform linux/amd64 --provenance=false -t "$IMAGE" "$CTX"
      docker push "$IMAGE"
    EOT
  }

  depends_on = [aws_ecr_repository.book]
}
