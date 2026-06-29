#!/bin/bash
# =============================================================================
# Bastion 부트스트랩 (cloud-init user_data)
#  - 목적: SSM 접속 후 바로 /opt/task2/deploy.sh 로 2과제 전체 배포가 가능하도록 준비
#  - 흐름: 도구 설치 → S3 에서 2과제 코드 번들 다운로드/해제 → deploy.sh 배치
#  - 도구: terraform / awscli / git / unzip / docker / buildx / kubectl / helm
#  - 로그: /var/log/bastion-bootstrap.log
#  - 완료 마커: /opt/task2/READY  (이 파일이 보이면 준비 완료)
# =============================================================================
set -eux
exec > /var/log/bastion-bootstrap.log 2>&1

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

# ---- 3) kubectl (EKS 1.35) ----
curl -sLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable-1.35.txt)/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# ---- 4) helm ----
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ---- 5) docker + buildx (module3/module4 가 docker build/push 사용) ----
systemctl enable --now docker
usermod -aG docker ec2-user || true
# SSM 접속 사용자(ssm-user)가 부팅 시점에 아직 없을 수 있어, 임시 bastion 한정으로
# docker 소켓을 개방해 누구나 docker 사용 가능하게 한다.
chmod 666 /var/run/docker.sock || true

mkdir -p /usr/libexec/docker/cli-plugins
curl -SL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
  -o /usr/libexec/docker/cli-plugins/docker-buildx
chmod +x /usr/libexec/docker/cli-plugins/docker-buildx

# ---- 6) 2과제 코드 번들 받기 ----
mkdir -p /opt/task2
aws s3 cp "s3://${bucket}/${bundle_key}" /tmp/task2.zip --region "${region}"
unzip -o /tmp/task2.zip -d /opt/task2

# ---- 7) deploy.sh 배치 (user_data writes /opt/task2/deploy.sh) ----
aws s3 cp "s3://${bucket}/${deploy_key}" /opt/task2/deploy.sh --region "${region}"

# 선수등번호 기본값(없으면 deploy.sh 인자로도 전달 가능)
echo "${competitor_number}" > /opt/task2/.competitor_number

# 실행 권한 + 누구나 작업 가능하도록 권한 개방(임시 bastion)
chmod +x /opt/task2/deploy.sh || true
chmod +x /opt/task2/module3/deploy_k8s.sh || true
chmod +x /opt/task2/module3/deploy.sh || true
chmod +x /opt/task2/module4/manifest/setup.sh || true
chmod -R 777 /opt/task2

# ---- 8) 완료 마커 ----
touch /opt/task2/READY
echo "BOOTSTRAP COMPLETE"
