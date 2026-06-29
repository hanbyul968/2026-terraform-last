#!/bin/bash
# =============================================================================
# Bastion 부트스트랩 (cloud-init user_data) — 전부 bash (Linux Bastion 실행)
#  - 목적: SSM 접속 후 바로 07/2과제 루트 terraform apply 가 가능하도록 자동 준비
#  - 흐름: 도구 설치 → S3에서 2과제 코드 번들 다운로드/해제 → tfvars/runner 생성
#  - 로그: /var/log/bastion-bootstrap.log
#  - 완료 마커: /opt/task2/READY  (이 파일이 보이면 준비 완료)
# =============================================================================
set -eux
exec > /var/log/bastion-bootstrap.log 2>&1

REGION="${region}"

# ---- 1) 기본 도구 ----
dnf install -y git docker yum-utils unzip tar jq

# AWS CLI v2 (AL2023 기본 포함, 없을 경우 대비)
if ! command -v aws >/dev/null 2>&1; then
  curl -SL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi

# ---- 2) terraform ----
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform

# ---- 3) kubectl (루트 module4 EKS 검증/재실행용) ----
curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# ---- 4) helm (k8s-apply.sh 가 KEDA/Karpenter 설치에 사용) ----
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ---- 5) docker + buildx (k8s-apply.sh 가 worker 이미지 build/push 에 사용) ----
systemctl enable --now docker
usermod -aG docker ec2-user || true
# SSM 접속 사용자(ssm-user)가 부팅 시점에 아직 없을 수 있어, 임시 bastion 한정으로
# docker 소켓을 개방해 누구나 docker 사용 가능하게 한다.
chmod 666 /var/run/docker.sock || true

mkdir -p /usr/libexec/docker/cli-plugins
curl -SL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
  -o /usr/libexec/docker/cli-plugins/docker-buildx
chmod +x /usr/libexec/docker/cli-plugins/docker-buildx

# ---- 6) 2과제 코드 번들 받기 (terraform 이 로컬 현재 파일을 S3 로 업로드해 둠) ----
mkdir -p /opt/task2
aws s3 cp "s3://${bucket}/${key}" /tmp/task2.zip --region "$REGION"
unzip -o /tmp/task2.zip -d /opt/task2

# 앱 스크립트 실행 권한 + 누구나 작업 가능하도록 권한 개방(임시 bastion)
chmod +x /opt/task2/k8s-apply.sh || true
find /opt/task2 -name "*.sh" -exec chmod +x {} \; || true
chmod -R 777 /opt/task2

# ---- 7) docdb_password tfvars (07 루트 변수; 기본값이 있으나 명시적으로 지정) ----
# 대회 당일 비밀번호를 바꾸려면 이 파일만 수정 후 run.sh 재실행.
cat > /opt/task2/terraform.tfvars <<'TFVARS'
docdb_password = "Skills2026!"
TFVARS

# ---- 8) 원클릭 실행 스크립트 ----
cat > /opt/task2/run.sh <<'RUN'
#!/bin/bash
# 07/2과제 루트(module1~4 + in-VPC bastion) 전체를 한 번에 배포한다.
# 루트 module4 의 in-VPC bastion 이 부팅하며 CoreDNS 패치 + k8s-apply.sh 를 자동 수행.
set -e
cd /opt/task2
terraform init -input=false
terraform apply -auto-approve -var-file=terraform.tfvars
echo ""
echo "================= OUTPUTS ================="
terraform output || true
RUN
chmod +x /opt/task2/run.sh

# ---- 9) 완료 마커 ----
touch /opt/task2/READY
echo "BOOTSTRAP COMPLETE"
