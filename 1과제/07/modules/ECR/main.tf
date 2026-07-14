resource "aws_ecr_repository" "concert_app" {
  name = var.repository_name

  # destroy 시 이미지가 남아 있어도 리포지토리를 삭제 (RepositoryNotEmpty 방지)
  force_delete = true

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = var.kms_key_arn
  }

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  tags = {
    Name = var.repository_name
  }

  lifecycle {
    ignore_changes = [image_tag_mutability]
  }
}
