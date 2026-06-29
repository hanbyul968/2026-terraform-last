# =============================================================================
# 최상위 오케스트레이터 (선택적 All-in-One Apply)
#
# ※ 2단계 배포 방식(권장): bastion/ 를 로컬에서 apply → SSM 접속 →
#   /opt/task2/deploy.sh 로 module1~4 일괄 배포. 이 deploy.sh 가 표준 경로다.
#
# 이 루트 오케스트레이터는 위 deploy.sh 와 동일한 순서를 terraform 으로도 돌릴 수
# 있게 남겨둔 "대안" 경로다. apply 가 Linux Bastion 에서 수행되므로 모든
# local-exec 는 PowerShell -> /bin/bash 로 변환되었다.
#
# 각 모듈(module1~4)은 여전히 독립 루트로서 standalone 실행이 가능하며
# (cd module1 && terraform apply), 자체 state 를 그대로 유지한다.
#
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

# (Deprecated on Linux) 과거 Windows Git Bash 경로. Linux Bastion 에서는 /bin/bash 사용.
variable "git_bash_path" {
  description = "[deprecated] Windows 전용. Linux Bastion 에서는 사용되지 않음."
  type        = string
  default     = "/bin/bash"
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
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      terraform -chdir="${local.m1}" init -input=false
      terraform -chdir="${local.m1}" apply -auto-approve -input=false
    EOT
  }

  # destroy 시(역순) : module1 정리
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = "terraform -chdir=\"${path.module}/module1\" destroy -auto-approve -input=false"
  }
}

# -----------------------------------------------------------------------------
# module2 — CDN Function (us-east-1)
# -----------------------------------------------------------------------------
resource "null_resource" "module2" {
  triggers = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      terraform -chdir="${local.m2}" init -input=false
      terraform -chdir="${local.m2}" apply -auto-approve -input=false
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = "terraform -chdir=\"${path.module}/module2\" destroy -auto-approve -input=false"
  }
}

# -----------------------------------------------------------------------------
# module3 — EKS Scaling (ap-northeast-2)
#   docker/kubeconfig 충돌 방지를 위해 module4 보다 먼저(순차) 실행.
# -----------------------------------------------------------------------------
resource "null_resource" "module3" {
  triggers = { always_run = timestamp() }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      terraform -chdir="${local.m3}" init -input=false
      terraform -chdir="${local.m3}" apply -auto-approve -input=false
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
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
  }

  # 4-1) 인프라 apply
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      terraform -chdir="${local.m4}" init -input=false
      terraform -chdir="${local.m4}" apply -auto-approve -input=false -var="competitor_number=${var.competitor_number}"
    EOT
  }

  # 4-2) setup.sh (run_module4_setup = true 일 때만)
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      if [ "${var.run_module4_setup}" = "true" ]; then
        cd "${local.m4}/manifest"
        number="${var.competitor_number}" bash ./setup.sh
      else
        echo "run_module4_setup=false : setup.sh 자동 실행을 건너뜀."
      fi
    EOT
  }

  # destroy 시(역순) : Helm 릴리스 제거 후 module4 destroy
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
      helm uninstall o11y-loki o11y-grafana -n monitoring 2>/dev/null || true
      terraform -chdir="${path.module}/module4" destroy -auto-approve -input=false -var="competitor_number=${self.triggers.competitor_number}"
    EOT
  }

  depends_on = [null_resource.module3]
}
