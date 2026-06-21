############################
# Bootstrap container 이미지 (hostname-override 설정용)
#   노드가 부팅 시 pull 하므로 nodegroup 생성 전에 ECR 에 올라가 있어야 한다.
#   ECR repo 생성 + docker build/push 를 terraform 이 직접 수행 (Windows/PowerShell).
#   전제: docker 와 aws CLI 가 PATH 에 있어야 함.
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
    interpreter = ["powershell", "-NoProfile", "-Command"]
    environment = {
      REGION   = local.region
      REGISTRY = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
      IMAGE    = "${aws_ecr_repository.bootstrap.repository_url}:latest"
      CTX      = "${path.module}/bootstrap-container"
    }
    command = <<-EOT
      $ErrorActionPreference = 'Stop'
      # PowerShell 파이프(| docker login --password-stdin)는 토큰 인코딩이 깨져
      # 400 Bad Request 가 나므로, 토큰을 변수로 받아 --password 로 전달한다.
      $pw = (aws ecr get-login-password --region $env:REGION) | Out-String
      $pw = $pw.Trim()
      docker login --username AWS --password $pw $env:REGISTRY
      if ($LASTEXITCODE -ne 0) { throw "docker login failed" }
      docker build --platform linux/amd64 --provenance=false -t $env:IMAGE $env:CTX
      if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
      docker push $env:IMAGE
      if ($LASTEXITCODE -ne 0) { throw "docker push failed" }
    EOT
  }

  depends_on = [aws_ecr_repository.bootstrap]
}
