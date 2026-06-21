# =============================================================================
# 6. ECR (Elastic Container Registry)
#  - 프라이빗 Repository: <id>-book-ecr
#  - 지급된 book 실행 파일로 Linux/AMD64 이미지 빌드 -> latest 태그 -> push
#
# ※ docker build/push는 null_resource(local-exec)로 자동화한다.
#   로컬에 Docker + AWS CLI v2가 필요하며, ECS Task Definition은 이 리소스에
#   의존(depends_on)하여 이미지가 push된 뒤 생성되도록 한다.
# =============================================================================

resource "aws_ecr_repository" "book" {
  name                 = local.ecr_repo
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = local.ecr_repo
  }
}

# 컨텍스트(app 디렉토리: Dockerfile + book) 변경 시 재빌드 트리거
locals {
  image_uri        = "${aws_ecr_repository.book.repository_url}:latest"
  ecr_registry     = split("/", aws_ecr_repository.book.repository_url)[0]
  dockerfile_hash  = filemd5("${path.module}/app/Dockerfile")
  book_binary_hash = filemd5("${path.module}/app/book")
}

resource "null_resource" "docker_build_push" {
  triggers = {
    image_uri   = local.image_uri
    dockerfile  = local.dockerfile_hash
    book_binary = local.book_binary_hash
    repository  = aws_ecr_repository.book.repository_url
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    working_dir = path.module
    command     = <<-EOT
      aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${local.ecr_registry}
      docker buildx build --platform linux/amd64 -t ${local.image_uri} --push ./app
    EOT
  }

  depends_on = [aws_ecr_repository.book]
}
