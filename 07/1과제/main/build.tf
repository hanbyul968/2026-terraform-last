# Docker build & push runs on the machine executing `terraform apply`.
# In this two-stage layout that machine is the bastion (created by ../bootstrap),
# which has Docker, the AWS CLI, and an admin instance profile.
resource "terraform_data" "docker_push" {
  triggers_replace = [
    aws_ecr_repository.book.repository_url,
    filemd5("${path.module}/app/Dockerfile"),
    filemd5("${path.module}/app/book"),
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      REGION="ap-northeast-2"
      ACCOUNT_ID="${data.aws_caller_identity.current.account_id}"
      REPO_URL="${aws_ecr_repository.book.repository_url}"

      aws ecr get-login-password --region "$REGION" \
        | sudo docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

      sudo docker build -t skills-book-app "${path.module}/app"
      sudo docker tag skills-book-app:latest "$REPO_URL:latest"
      sudo docker push "$REPO_URL:latest"
    EOT
  }

  depends_on = [aws_ecr_repository.book]
}
