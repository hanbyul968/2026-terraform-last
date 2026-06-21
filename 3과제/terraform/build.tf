# Build and push container images to ECR from the provided prebuilt binaries
# (application/binary/{user,product,stress}, static x86-64 Go executables).
# Target runtime: AWS CloudShell (Amazon Linux 2023) — local-exec uses bash + Docker.
resource "null_resource" "build_push" {
  triggers = {
    user_bin    = filesha256("${path.module}/../application/binary/user")
    product_bin = filesha256("${path.module}/../application/binary/product")
    stress_bin  = filesha256("${path.module}/../application/binary/stress")
    tag         = var.app_image_tag
  }

  depends_on = [aws_ecr_repository.this]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    working_dir = "${path.module}/../application/binary"
    environment = local.exec_env
    command     = <<-EOT
      set -euo pipefail
      registry="${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
      aws ecr get-login-password --region ${var.region} \
        | docker login --username AWS --password-stdin "$registry"
      for app in user product stress; do
        chmod +x "$app"
        printf 'FROM gcr.io/distroless/static-debian12:nonroot\nCOPY %s /app\nEXPOSE 8080\nENTRYPOINT ["/app"]\n' "$app" > "Dockerfile.$app"
        docker build --platform linux/amd64 -f "Dockerfile.$app" \
          -t "$registry/${local.name}/$app:${var.app_image_tag}" .
        docker push "$registry/${local.name}/$app:${var.app_image_tag}"
        rm -f "Dockerfile.$app"
      done
    EOT
  }
}
