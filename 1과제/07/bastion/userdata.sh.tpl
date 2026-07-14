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

# ---- 1) 기본 도구 ----
dnf install -y git yum-utils unzip tar gzip jq

# AWS CLI v2 (AL2023 기본 포함, 없을 경우 대비)
if ! command -v aws >/dev/null 2>&1; then
  curl -SL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi

# ---- 2) terraform ----
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform

# ---- 3) kubectl (k8s provider 인증 디버깅용) ----
curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# ---- 3-1) docker (manifest/apply.sh 의 이미지 빌드/푸시에 필수) ----
#   apply.sh 는 이 Bastion 에서 실행된다. docker 가 없으면 book 이미지(v1.0.0)가
#   ECR 로 push 되지 않아 Pod 가 ImagePullBackOff → 앱 502 로 전부 실패한다.
dnf install -y docker
systemctl enable --now docker
# apply.sh 를 실행하는 ssm-user / ec2-user 가 sudo 없이 docker 를 쓸 수 있도록
usermod -aG docker ec2-user 2>/dev/null || true
usermod -aG docker ssm-user 2>/dev/null || true
# (eksctl/helm 은 apply.sh 가 curl 로 자체 설치한다)

# ---- 4) 1과제 코드 번들 받기 (terraform 이 로컬 현재 파일을 S3 로 업로드해 둠) ----
mkdir -p /opt/task1
aws s3 cp "s3://${bucket}/${key}" /tmp/task1.zip --region "${region}"
unzip -o /tmp/task1.zip -d /opt/task1

# 지급 바이너리 실행 권한 + 누구나 작업 가능하도록 권한 개방(임시 bastion)
chmod +x /opt/task1/docker/book || true
chmod +x /opt/task1/docker/test/book || true
chmod -R 777 /opt/task1

# ---- 5) 루트 변수 파일(terraform.tfvars) 작성 (no-default 변수만) ----
cat > /opt/task1/terraform.tfvars <<TFVARS
number = "${number}"
TFVARS

# ---- 6) 원클릭 실행 스크립트 ----
cat > /opt/task1/run.sh <<'RUN'
#!/bin/bash
# main(루트 1과제) 인프라를 한 번에 배포한다.
#  - 변수는 /opt/task1/terraform.tfvars (number) 로 자동 로드된다.
set -e
cd /opt/task1
terraform init -input=false
terraform apply -auto-approve
echo ""
echo "================= OUTPUTS ================="
terraform output || true
RUN
chmod +x /opt/task1/run.sh

# ---- 7) 완료 마커 ----
touch /opt/task1/READY
echo "BOOTSTRAP COMPLETE"
