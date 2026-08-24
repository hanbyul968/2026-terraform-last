# ECR 레포지토리 — 앱 목록(local.apps)에서 자동 생성.
# 대회날 앱이 바뀌면 application/binary/ 의 바이너리만 교체하면 레포도 따라 생긴다.
resource "aws_ecr_repository" "this" {
  for_each             = local.apps
  name                 = "${local.name}/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
