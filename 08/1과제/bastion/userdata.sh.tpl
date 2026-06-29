#!/bin/bash
# =============================================================================
# Bastion 부트스트랩 (cloud-init user_data)
#  - 목적: SSM 접속 후 바로 main terraform apply가 가능하도록 모든 것을 자동 준비
#  - 흐름: 도구 설치 → S3에서 1과제 코드 번들 다운로드/해제 → tfvars/runner 생성
#  - 로그: /var/log/bastion-bootstrap.log
#  - 완료 마커: /opt/task1/READY  (이 파일이 보이면 준비 완료)
# =============================================================================
set -eux
exec > /var/log/bastion-bootstrap.log 2>&1

# ---- 1) 기본 도구 ----
dnf install -y git docker yum-utils unzip tar

# AWS CLI v2 (AL2023에 기본 포함되지만 없을 경우 대비)
if ! command -v aws >/dev/null 2>&1; then
  curl -SL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi

# ---- 2) terraform ----
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform

# ---- 3) docker + buildx (main ecr.tf가 docker buildx 사용) ----
systemctl enable --now docker
usermod -aG docker ec2-user || true
# SSM 접속 사용자(ssm-user)는 부팅 시점에 아직 없을 수 있으므로,
# 던져버릴 임시 bastion 한정으로 docker 소켓을 개방해 누구나 docker 사용 가능하게 한다.
chmod 666 /var/run/docker.sock || true

mkdir -p /usr/libexec/docker/cli-plugins
curl -SL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
  -o /usr/libexec/docker/cli-plugins/docker-buildx
chmod +x /usr/libexec/docker/cli-plugins/docker-buildx

# ---- 4) 1과제 코드 번들 받기 (terraform이 로컬 현재 파일을 S3로 업로드해 둠) ----
mkdir -p /opt/task1
aws s3 cp "s3://${bucket}/${key}" /tmp/task1.zip --region "${region}"
unzip -o /tmp/task1.zip -d /opt/task1

# 지급 바이너리 실행 권한 + 누구나 작업 가능하도록 권한 개방(임시 bastion)
chmod +x /opt/task1/app/book || true
chmod -R 777 /opt/task1

# ---- 5) 비번호 자동 주입 (apply 시 -var 불필요) ----
cat > /opt/task1/terraform.tfvars <<TFVARS
player_id = "${player_id}"
region    = "${region}"
TFVARS

# ---- 6) 원클릭 실행 스크립트 ----
cat > /opt/task1/run.sh <<'RUN'
#!/bin/bash
# main 인프라를 한 번에 배포한다. (docker build/push 포함)
set -e
cd /opt/task1
terraform init -input=false
terraform apply -auto-approve
echo ""
echo "================= OUTPUTS ================="
terraform output
RUN
chmod +x /opt/task1/run.sh

# ---- 7) 완료 마커 ----
touch /opt/task1/READY
echo "BOOTSTRAP COMPLETE"
