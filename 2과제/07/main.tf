# =============================================================================
# Windows All-in-One 오케스트레이터
#
# 각 module은 독립 Terraform root/state를 유지한다. 이 root는 PowerShell 실행기를
# 통해 module1~4를 순서대로 apply하고, module3/4의 Kubernetes 후처리까지 수행한다.
#
# [실행]
#   terraform init
#   terraform apply -var="competitor_number=<선수등번호>"
#
# 중요: null_resource 교체 시 하위 인프라를 먼저 삭제하지 않도록 destroy-time
# provisioner를 사용하지 않는다. 전체 삭제는 README의 모듈별 teardown을 사용한다.
# =============================================================================

terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

variable "competitor_number" {
  description = "선수등번호 (module4 Grafana 계정/비밀번호에 사용)"
  type        = string

  validation {
    condition     = length(trimspace(var.competitor_number)) > 0
    error_message = "competitor_number must not be empty."
  }
}

variable "git_bash_path" {
  description = "module4 setup.sh 실행에 사용할 Windows Git Bash 경로"
  type        = string
  default     = "C:/Program Files/Git/bin/bash.exe"
}

variable "run_module3_setup" {
  description = "module3 apply 후 SSM Bastion에서 KEDA/Karpenter/App을 자동 배포할지 여부"
  type        = bool
  default     = true
}

variable "run_module4_setup" {
  description = "module4 apply 후 로컬 Git Bash에서 이미지/Helm/대시보드를 자동 배포할지 여부"
  type        = bool
  default     = true
}

locals {
  m1     = "${path.module}/module1"
  m2     = "${path.module}/module2"
  m3     = "${path.module}/module3"
  m4     = "${path.module}/module4"
  runner = "${path.module}/scripts/run-module.ps1"

  # timestamp() 대신 실제 입력 파일 hash만 trigger로 사용한다. 따라서 평범한
  # terraform apply는 인프라 destroy/recreate 없이 no-op이고, 코드가 바뀐
  # 모듈만 idempotent하게 다시 apply된다.
  module1_hash = sha256(join("", [
    filesha256("${local.m1}/main.tf"),
    filesha256("${local.m1}/app.py"),
    filesha256("${local.m1}/lambda.py"),
    filesha256("${local.m1}/requirements.txt"),
    filesha256(local.runner),
  ]))
  module2_hash = sha256(join("", [
    filesha256("${local.m2}/main.tf"),
    filesha256("${local.m2}/cf_req_fn.js"),
    filesha256("${local.m2}/cf_res_fn.js"),
    filesha256("${local.m2}/index_a.html"),
    filesha256("${local.m2}/index_b.html"),
    filesha256(local.runner),
  ]))
  module3_hash = sha256(join("", [
    filesha256("${local.m3}/main.tf"),
    filesha256("${local.m3}/deploy.sh"),
    filesha256("${local.m3}/k8s-app.yaml"),
    filesha256("${local.m3}/k8s-keda.yaml"),
    filesha256("${local.m3}/k8s-karpenter.yaml"),
    filesha256("${local.m3}/app/app.py"),
    filesha256("${local.m3}/app/Dockerfile"),
    filesha256("${local.m3}/app/requirements.txt"),
    filesha256(local.runner),
  ]))
  module4_hash = sha256(join("", [
    filesha256("${local.m4}/main.tf"),
    filesha256("${local.m4}/manifest/setup.sh"),
    filesha256("${local.m4}/manifest/app.py"),
    filesha256("${local.m4}/manifest/Dockerfile"),
    filesha256(local.runner),
  ]))
}

resource "null_resource" "module1" {
  triggers = {
    source_hash = local.module1_hash
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
    working_dir = path.module
    command     = <<-EOT
      & "${local.runner}" -Module "module1" -CompetitorNumber "${var.competitor_number}" -RunWorkloadSetup "false" -GitBashPath "${var.git_bash_path}"
    EOT
  }
}

resource "null_resource" "module2" {
  triggers = {
    source_hash = local.module2_hash
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
    working_dir = path.module
    command     = <<-EOT
      & "${local.runner}" -Module "module2" -CompetitorNumber "${var.competitor_number}" -RunWorkloadSetup "false" -GitBashPath "${var.git_bash_path}"
    EOT
  }
}

resource "null_resource" "module3" {
  triggers = {
    source_hash        = local.module3_hash
    run_workload_setup = tostring(var.run_module3_setup)
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
    working_dir = path.module
    command     = <<-EOT
      & "${local.runner}" -Module "module3" -CompetitorNumber "${var.competitor_number}" -RunWorkloadSetup "${var.run_module3_setup}" -GitBashPath "${var.git_bash_path}"
    EOT
  }

  depends_on = [null_resource.module1, null_resource.module2]
}

resource "null_resource" "module4" {
  triggers = {
    source_hash        = local.module4_hash
    competitor_number  = var.competitor_number
    git_bash_path      = var.git_bash_path
    run_workload_setup = tostring(var.run_module4_setup)
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
    working_dir = path.module
    command     = <<-EOT
      & "${local.runner}" -Module "module4" -CompetitorNumber "${var.competitor_number}" -RunWorkloadSetup "${var.run_module4_setup}" -GitBashPath "${var.git_bash_path}"
    EOT
  }

  depends_on = [null_resource.module3]
}
