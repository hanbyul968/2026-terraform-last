#!/bin/bash
# =============================================================================
# Bastion 부트스트랩 (cloud-init user_data)
#  - 목적: SSM 접속 후 바로 main terraform apply 가 가능하도록 모든 것을 자동 준비
#  - 흐름: 도구 설치 → S3에서 1과제 코드 번들 다운로드/해제 → tfvars/runner 생성
#  - 로그: /var/log/bastion-bootstrap.log
#  - 완료 마커: /opt/task1/READY  (이 파일이 보이면 준비 완료)
# =============================================================================
set -eux
exec > /var/log/bastion-bootstrap.log 2>&1

# ---- 1) 기본 도구 (git/awscli/kubectl/unzip 등) ----
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

# ---- 3) kubectl (aws-auth.tf 의 kubectl apply / 디버깅용) ----
curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# ---- 4) docker + buildx (root build-bootstrap.tf 가 docker build/push 사용) ----
systemctl enable --now docker
usermod -aG docker ec2-user || true
# SSM 접속 사용자(ssm-user)가 부팅 시점에 아직 없을 수 있어, 임시 bastion 한정으로
# docker 소켓을 개방해 누구나 docker 사용 가능하게 한다.
chmod 666 /var/run/docker.sock || true

mkdir -p /usr/libexec/docker/cli-plugins
curl -SL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
  -o /usr/libexec/docker/cli-plugins/docker-buildx
chmod +x /usr/libexec/docker/cli-plugins/docker-buildx

# ---- 4b) helm (앱 배포: LBC/grafana helm 설치). 실패해도 부트스트랩은 계속 → READY 생성 보장 ----
#   get.helm.sh 가 간헐적으로 느려 연결 타임아웃이 날 수 있어 재시도한다.
#   set +e 로 감싸 실패해도 부트스트랩을 중단하지 않는다(READY 를 반드시 만들기 위함).
#   eksctl 은 배포 스크립트에서 사용하지 않으므로 설치하지 않는다.
set +e
HELM_VER="v3.16.3"
for i in 1 2 3 4 5 6; do
  curl -fsSL --connect-timeout 15 --max-time 180 \
    "https://get.helm.sh/helm-$${HELM_VER}-linux-amd64.tar.gz" -o /tmp/helm.tgz \
    && tar xzf /tmp/helm.tgz -C /tmp \
    && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm \
    && break
  echo "helm install retry $i failed; sleeping 15s..."; sleep 15
done
command -v helm || echo "WARNING: helm not installed in userdata (deploy 단계에서 재시도)"
set -e

# ---- 5) 1과제 코드 번들 받기 (terraform 이 로컬 현재 파일을 S3 로 업로드해 둠) ----
mkdir -p /opt/task1
aws s3 cp "s3://${bucket}/${key}" /tmp/task1.zip --region "${region}"
unzip -o /tmp/task1.zip -d /opt/task1

# 지급 바이너리 실행 권한 (book 앱 바이너리)
chmod +x /opt/task1/application/book-linux-amd64_v1.0.1 || true
# 누구나 작업 가능하도록 권한 개방(임시 bastion)
chmod -R 777 /opt/task1

# ---- 6) 루트가 요구하는 no-default 변수 주입 (terraform.tfvars) ----
cat > /opt/task1/terraform.tfvars <<TFVARS
bi_number = "${bi_number}"
TFVARS

# ---- 7) 원클릭 실행 스크립트 ----
cat > /opt/task1/run.sh <<'RUN'
#!/bin/bash
# main(루트 1과제) 인프라를 한 번에 배포한다. (docker build/push 포함)
set -e
cd /opt/task1
terraform init -input=false
terraform apply -auto-approve
echo ""
echo "================= OUTPUTS ================="
terraform output || true
RUN
chmod +x /opt/task1/run.sh

# ---- 8) 완료 마커 ----
touch /opt/task1/READY
echo "BOOTSTRAP COMPLETE"
