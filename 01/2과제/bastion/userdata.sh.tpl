#!/bin/bash
# =============================================================================
# Bastion 부트스트랩 (cloud-init user_data)
#  - 목적: SSM 접속 후 바로 2과제 4개 모듈 apply 가 가능하도록 모든 것을 자동 준비
#  - 흐름: 도구 설치 -> S3에서 2과제 코드 번들 다운로드/해제 -> deploy.sh 생성
#  - 로그: /var/log/bastion-bootstrap.log
#  - 완료 마커: /opt/task2/READY  (이 파일이 보이면 준비 완료)
# =============================================================================
set -eux
exec > /var/log/bastion-bootstrap.log 2>&1

# ---- 1) 기본 도구 (zip: module-2 pymysql layer 빌드, python3-pip: pip3) ----
dnf install -y git docker yum-utils unzip zip tar jq python3-pip

# AWS CLI v2 (AL2023 기본 포함, 없을 경우 대비)
if ! command -v aws >/dev/null 2>&1; then
  curl -SL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi

# ---- 2) terraform ----
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform

# ---- 3) kubectl (디버깅용; 2과제는 직접 사용 안 함) ----
curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl || true

# ---- 4) docker + buildx ----
systemctl enable --now docker
usermod -aG docker ec2-user || true
chmod 666 /var/run/docker.sock || true

mkdir -p /usr/libexec/docker/cli-plugins
curl -SL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
  -o /usr/libexec/docker/cli-plugins/docker-buildx
chmod +x /usr/libexec/docker/cli-plugins/docker-buildx

# ---- 5) 2과제 코드 번들 받기 (terraform 이 로컬 현재 파일을 S3 로 업로드해 둠) ----
mkdir -p /opt/task2
aws s3 cp "s3://${bucket}/${key}" /tmp/task2.zip --region "${region}"
unzip -o /tmp/task2.zip -d /opt/task2

# 누구나 작업 가능하도록 권한 개방(임시 bastion)
chmod -R 777 /opt/task2

# ---- 6) 순차 배포 스크립트 (module-1 -> module-2 -> module-3 -> module-4) ----
#   권위 모듈 세트: module-1 ~ module-4 (각 폴더에 main.tf 존재).
#   빈 module1~module4 세트(.tf 없음)는 배포 대상에서 제외한다.
cat > /opt/task2/deploy.sh <<'RUN'
#!/bin/bash
# 2과제 4개 모듈(멀티 리전)을 순서대로 배포한다.
#   module-1 ap-northeast-2 : DynamoDB + Lambda + API Gateway
#   module-2 ap-northeast-1 : VPC + RDS(MySQL) + RDS Proxy + Secrets + Lambda(pymysql layer)
#   module-3 us-east-1      : DynamoDB + S3 + EventBridge + Step Functions + Lambda
#   module-4 ap-southeast-1 : VPC + Client VPN + EC2 + TLS/ACM
set -e
BASE=/opt/task2
for m in module-1 module-2 module-3 module-4; do
  echo ""
  echo "================= APPLY $m ================="
  cd "$BASE/$m"
  terraform init -input=false
  terraform apply -auto-approve
  echo "----------------- OUTPUTS $m -----------------"
  terraform output || true
done
echo ""
echo "================= ALL MODULES DEPLOYED ================="
RUN
chmod +x /opt/task2/deploy.sh

# ---- 7) 완료 마커 ----
touch /opt/task2/READY
echo "BOOTSTRAP COMPLETE"
