# Build and push container images to ECR from the provided prebuilt binaries
# (application/binary/{user,product,stress}, static x86-64 Go executables).
#
# Cross-platform: the commands below contain NO shell variables or loops — every
# value is interpolated by terraform — so the exact same lines run identically
# under Linux /bin/sh (CloudShell) and Windows PowerShell. Pick the interpreter
# with -var is_windows=true on Windows (PowerShell, no bash required).
locals {
  ecr_registry = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"

  # one "build + push" pair per app, fully interpolated (no shell vars)
  build_lines = join("\n", flatten([
    for app in ["user", "product", "stress"] : [
      "docker build --platform linux/amd64 --build-arg APP=${app} -t ${local.ecr_registry}/${local.name}/${app}:${var.app_image_tag} .",
      "docker push ${local.ecr_registry}/${local.name}/${app}:${var.app_image_tag}",
    ]
  ]))

  # sh/bash: stdin pipe works correctly here.
  ecr_login_sh = "aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${local.ecr_registry}"

  # PowerShell: piping the token to --password-stdin corrupts it (encoding/BOM
  # → 400 Bad Request), so pass the captured token as an argument instead.
  ecr_login_ps = "docker login --username AWS --password (aws ecr get-login-password --region ${var.region}) ${local.ecr_registry}"

  # sh: `set -e` aborts on first failure (pipefail intentionally NOT used — not
  # POSIX, and some Windows bashes reject it).
  build_cmd_sh = "set -e\n${local.ecr_login_sh}\n${local.build_lines}\n"

  # PowerShell: native-command failures don't stop automatically, so check
  # $LASTEXITCODE after each line.
  build_cmd_ps = "$ErrorActionPreference='Stop'\n${join("\n", [for l in concat([local.ecr_login_ps], split("\n", local.build_lines)) : "${l}; if ($LASTEXITCODE -ne 0) { throw 'command failed' }"])}\n"

  build_interpreter = var.is_windows ? ["powershell", "-NoProfile", "-Command"] : ["/bin/sh", "-c"]
  build_command     = var.is_windows ? local.build_cmd_ps : local.build_cmd_sh
}

resource "null_resource" "build_push" {
  triggers = {
    user_bin    = filesha256("${path.module}/../application/binary/user")
    product_bin = filesha256("${path.module}/../application/binary/product")
    stress_bin  = filesha256("${path.module}/../application/binary/stress")
    dockerfile  = filesha256("${path.module}/../application/binary/Dockerfile")
    tag         = var.app_image_tag
  }

  depends_on = [aws_ecr_repository.this]

  provisioner "local-exec" {
    interpreter = local.build_interpreter
    working_dir = "${path.module}/../application/binary"
    environment = local.exec_env
    command     = local.build_command
  }
}
