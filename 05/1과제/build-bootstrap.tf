############################
# Bootstrap container 이미지 (hostname-override 설정용)
#   노드가 부팅 시 pull 하므로 nodegroup 생성 전에 ECR 에 올라가 있어야 한다.
#   ECR repo 생성 + docker build/push 를 terraform 이 직접 수행 (Linux Bastion/bash).
#   전제: docker(+buildx) 와 aws CLI 가 PATH 에 있어야 함 (bastion userdata 가 설치).
############################

resource "aws_ecr_repository" "bootstrap" {
  name                 = "gj2026-bootstrap"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "null_resource" "build_push_bootstrap" {
  # 소스가 바뀌면 다시 빌드/푸시
  triggers = {
    dockerfile = filemd5("${path.module}/bootstrap-container/Dockerfile")
    script     = filemd5("${path.module}/bootstrap-container/bootstrap.sh")
    repo       = aws_ecr_repository.bootstrap.repository_url
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION   = local.region
      REGISTRY = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
      IMAGE    = "${aws_ecr_repository.bootstrap.repository_url}:latest"
      CTX      = "${path.module}/bootstrap-container"
    }
    command = <<-EOT
      set -eu
      # Linux/bash 에서는 표준 방식대로 토큰을 파이프로 password-stdin 에 전달한다.
      aws ecr get-login-password --region "$REGION" \
        | docker login --username AWS --password-stdin "$REGISTRY"
      docker build --platform linux/amd64 --provenance=false -t "$IMAGE" "$CTX"
      docker push "$IMAGE"
    EOT
  }

  depends_on = [aws_ecr_repository.bootstrap]
}
