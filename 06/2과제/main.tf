# =============================================================================
# 최상위 오케스트레이터 (All-in-One Apply)
#
# 이 루트에서 `terraform apply` 한 번이면 module1~4 를 순서대로
#   terraform init + apply (+ module4 는 setup.sh 까지) 자동 실행한다.
#
# 각 모듈(module1~4)은 여전히 독립 루트로서 standalone 실행이 가능하며
# (cd module1 && terraform apply), 자체 state 를 그대로 유지한다.
# 이 오케스트레이터는 null_resource + local-exec 로 각 모듈을 호출만 한다.
#
# [사전 조건] docker 동작 환경 + aws/terraform/kubectl/helm/jq/bash(Git Bash).
# [실행]  terraform init && terraform apply -var="competitor_number=<번호>"
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
  description = "선수등번호 (module4 Grafana 계정/비번 및 setup.sh 에 사용)"
  type        = string
}

# setup.sh 실행에 사용할 Git Bash 경로 (Windows). 환경에 맞게 조정 가능.
variable "git_bash_path" {
  description = "module4 setup.sh 실행용 bash 경로"
  type        = string
  default     = "C:\\Program Files\\Git\\bin\\bash.exe"
}

# module4 setup.sh(이미지 빌드/Helm/대시보드)를 apply 시 자동 실행할지 여부.
variable "run_module4_setup" {
  description = "true 면 module4 apply 후 setup.sh 자동 실행"
  type        = bool
  default     = true
}

locals {
  m1 = "${path.module}/module1"
  m2 = "${path.module}/module2"
  m3 = "${path.module}/module3"
  m4 = "${path.module}/module4"
}

# -----------------------------------------------------------------------------
# module1 — NoSQL (ap-southeast-1)
# -----------------------------------------------------------------------------
resource "null_resource" "module1" {
  triggers = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["powershell", "-NoProfile", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"
      terraform -chdir="${local.m1}" init -input=false
      terraform -chdir="${local.m1}" apply -auto-approve -input=false
    EOT
  }

  # destroy 시(역순) : module1 정리
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["powershell", "-NoProfile", "-Command"]
    command     = "terraform -chdir=\"${path.module}/module1\" destroy -auto-approve -input=false"
  }
}

# -----------------------------------------------------------------------------
# module2 — CDN Function (us-east-1)
# -----------------------------------------------------------------------------
resource "null_resource" "module2" {
  triggers = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["powershell", "-NoProfile", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"
      terraform -chdir="${local.m2}" init -input=false
      terraform -chdir="${local.m2}" apply -auto-approve -input=false
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["powershell", "-NoProfile", "-Command"]
    command     = "terraform -chdir=\"${path.module}/module2\" destroy -auto-approve -input=false"
  }
}

# -----------------------------------------------------------------------------
# module3 — EKS Scaling (ap-northeast-2)
#   자체 apply 안에서 ECR 빌드/푸시 + EKS/KEDA/Karpenter/워크로드까지 완료됨.
#   docker/kubeconfig 충돌 방지를 위해 module4 보다 먼저(순차) 실행.
# -----------------------------------------------------------------------------
resource "null_resource" "module3" {
  triggers = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["powershell", "-NoProfile", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"
      terraform -chdir="${local.m3}" init -input=false
      terraform -chdir="${local.m3}" apply -auto-approve -input=false
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["powershell", "-NoProfile", "-Command"]
    command     = "terraform -chdir=\"${path.module}/module3\" destroy -auto-approve -input=false"
  }

  depends_on = [null_resource.module1, null_resource.module2]
}

# -----------------------------------------------------------------------------
# module4 — Container Logging / O11y (ap-northeast-1)
#   1) terraform apply (인프라)  2) setup.sh (이미지 빌드/Helm/워크로드/대시보드)
# -----------------------------------------------------------------------------
resource "null_resource" "module4" {
  triggers = {
    always_run        = timestamp()
    competitor_number = var.competitor_number
    git_bash_path     = var.git_bash_path
  }

  # 4-1) 인프라 apply
  provisioner "local-exec" {
    interpreter = ["powershell", "-NoProfile", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"
      terraform -chdir="${local.m4}" init -input=false
      terraform -chdir="${local.m4}" apply -auto-approve -input=false -var="competitor_number=${var.competitor_number}"
    EOT
  }

  # 4-2) setup.sh (run_module4_setup = true 일 때만)
  provisioner "local-exec" {
    interpreter = ["powershell", "-NoProfile", "-Command"]
    command     = <<-EOT
      $ErrorActionPreference = "Stop"
      if ("${var.run_module4_setup}" -eq "true") {
        $env:number = "${var.competitor_number}"
        Push-Location "${local.m4}/manifest"
        & "${var.git_bash_path}" ./setup.sh
        Pop-Location
      } else {
        Write-Host "run_module4_setup=false : setup.sh 자동 실행을 건너뜀."
      }
    EOT
  }

  # destroy 시(역순) : Helm 릴리스 제거 후 module4 destroy
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["powershell", "-NoProfile", "-Command"]
    command     = <<-EOT
      helm uninstall aws-load-balancer-controller -n kube-system 2>$null
      helm uninstall o11y-loki o11y-grafana -n monitoring 2>$null
      terraform -chdir="${path.module}/module4" destroy -auto-approve -input=false -var="competitor_number=${self.triggers.competitor_number}"
    EOT
  }

  depends_on = [null_resource.module3]
}
