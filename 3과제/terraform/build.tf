# Build and push container images to ECR from the provided prebuilt binaries
# (application/binary/{user,product,stress}, static x86-64 Go executables).
#
# Cross-platform: the commands below contain NO shell variables or loops — every
# value is interpolated by terraform — so the exact same lines run identically
# under Linux /bin/sh (CloudShell) and Windows PowerShell. Pick the interpreter
# with -var is_windows=true on Windows (PowerShell, no bash required).
locals {
  ecr_registry = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"

  # 앱 바이너리 hash → 이미지 태그 자동 파생. 바이너리가 바뀌면 태그가 바뀌어
  # 자동 롤링 업데이트. -var app_image_tag 로 강제 override 가능.
  app_bins = {
    user    = filesha256("${path.module}/../application/binary/user")
    product = filesha256("${path.module}/../application/binary/product")
    stress  = filesha256("${path.module}/../application/binary/stress")
  }
  dockerfile_hash = filesha256("${path.module}/../application/binary/Dockerfile")
  app_image_tags = {
    for app, h in local.app_bins :
    app => var.app_image_tag != "latest" ? var.app_image_tag : substr(sha256("${h}${local.dockerfile_hash}"), 0, 12)
  }

  # one "build + push" pair per app, fully interpolated (no shell vars)
  build_lines = join("\n", flatten([
    for app in ["user", "product", "stress"] : [
      "docker build --platform linux/amd64 --build-arg APP=${app} -t ${local.ecr_registry}/${local.name}/${app}:${local.app_image_tags[app]} .",
      "docker push ${local.ecr_registry}/${local.name}/${app}:${local.app_image_tags[app]}",
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
    user_bin    = local.app_bins["user"]
    product_bin = local.app_bins["product"]
    stress_bin  = local.app_bins["stress"]
    dockerfile  = local.dockerfile_hash
    tags        = join(",", values(local.app_image_tags))
    # 매 apply 마다 재실행 → ECR 이 비어있거나(외부 삭제/repo 재생성) state 와
    # 어긋나도 항상 이미지를 다시 push 하여 ImagePullBackOff 를 원천 차단.
    # docker 레이어 캐시로 재실행은 빠르고, 이미지 태그는 hash 기반이라
    # 앱이 안 바뀌면 파드 롤링도 발생하지 않음(불필요한 재배포 없음).
    always = timestamp()
  }

  depends_on = [aws_ecr_repository.this]

  provisioner "local-exec" {
    interpreter = local.build_interpreter
    working_dir = "${path.module}/../application/binary"
    environment = local.exec_env
    command     = local.build_command
  }
}
