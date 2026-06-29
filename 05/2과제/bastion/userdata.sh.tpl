#!/bin/bash
# =============================================================================
# Bastion 부트스트랩 (cloud-init user_data)
#  - 목적: SSM 접속 후 바로 05/2과제 루트(4개 모듈) terraform apply 가 가능하도록
#          모든 도구와 코드 번들을 자동 준비한다.
#  - 흐름: 도구 설치 → S3에서 2과제 코드 번들 다운로드/해제 → deploy.sh 생성
#  - 로그: /var/log/bastion-bootstrap.log
#  - 완료 마커: /opt/task2/READY  (이 파일이 보이면 준비 완료)
# =============================================================================
set -eux
exec > /var/log/bastion-bootstrap.log 2>&1

# ---- 1) 기본 도구 ----
dnf install -y git docker yum-utils unzip tar jq python3 python3-pip

# AWS CLI v2 (AL2023 기본 포함, 없을 경우 대비)
if ! command -v aws >/dev/null 2>&1; then
  curl -SL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi

# ---- 2) terraform ----
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform

# ---- 3) kubectl (도구 목록 요구사항; 본 과제엔 직접 사용처 없음) ----
curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# ---- 4) helm (도구 목록 요구사항) ----
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get-helm-3
chmod +x /tmp/get-helm-3
/tmp/get-helm-3 || true

# ---- 5) docker + buildx ----
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
aws s3 cp "s3://${bucket}/${key}" /tmp/task2.zip --region "${region}"
unzip -o /tmp/task2.zip -d /opt/task2

# 변환된 bash provisioner 실행 권한 + 누구나 작업 가능하도록 권한 개방(임시 bastion)
find /opt/task2 -name "*.sh" -exec chmod +x {} \; || true
chmod -R 777 /opt/task2

# ---- 7) 원클릭 배포 스크립트 (README 의 단일 루트 apply 흐름을 bash 로 재현) ----
# 루트 main.tf 가 provider alias 로 4개 모듈을 한 번의 apply 로 오케스트레이션한다.
#   Module1 us-east-1   CDN          → null_resource.pillow_build 가 build.sh 실행
#   Module2 ap-southeast-1 Kafka/Flink → null_resource.zeppelin 가 zeppelin.sh 실행
#   Module3 ap-northeast-2 event       → (provisioner 없음, EC2 user_data 로 처리)
#   Module4 eu-central-1   Keycloak    → oidc.sh → iam-roles.sh 순차 실행
# 위 .sh 들은 local-exec provisioner 로 apply 중 올바른 시점에 자동 호출된다.
cat > /opt/task2/deploy.sh <<'DEPLOY'
#!/bin/bash
# 05/2과제 4개 모듈을 한 번에 배포한다.
#   사용: bash /opt/task2/deploy.sh [pin] [alarm_email]
#   기본값(미입력 시): pin=주입값, alarm_email=주입값
set -euo pipefail
cd /opt/task2

PIN="$${1:-${pin}}"
ALARM_EMAIL="$${2:-${alarm_email}}"

echo "[deploy] pin=$PIN alarm_email=$ALARM_EMAIL"
terraform init -input=false

if [ -n "$ALARM_EMAIL" ]; then
  terraform apply -auto-approve -var "pin=$PIN" -var "alarm_email=$ALARM_EMAIL"
else
  terraform apply -auto-approve -var "pin=$PIN"
fi

echo ""
echo "================= OUTPUTS ================="
terraform output || true
echo ""
echo "※ Module2 Zeppelin 노트북 SQL(2-3~2-5)과 Module3 SNS 이메일 구독 확인은"
echo "  module2/FLINK-NOTEBOOK.md / README.md 절차를 따르세요."
DEPLOY
chmod +x /opt/task2/deploy.sh

# ---- 8) 완료 마커 ----
touch /opt/task2/READY
echo "BOOTSTRAP COMPLETE"
