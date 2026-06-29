#!/bin/bash
# =============================================================================
# 03/2과제 Bastion 부트스트랩 (cloud-init user_data)
#  - 흐름: 도구 설치 -> S3에서 2과제 코드 번들 다운로드/해제 -> deploy.sh 생성
#  - 로그: /var/log/bastion-bootstrap.log
#  - 완료 마커: /opt/task2/READY
# =============================================================================
set -eux
exec > /var/log/bastion-bootstrap.log 2>&1

# ---- 1) 기본 도구 (zip/python3-pip: module1 Pillow 빌드, jq: module2 setup) ----
dnf install -y git docker yum-utils unzip zip tar jq python3 python3-pip

if ! command -v aws >/dev/null 2>&1; then
  curl -SL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi

# ---- 2) terraform ----
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform

# ---- 3) kubectl (module3 EKS) ----
curl -sLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable-1.35.txt)/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# ---- 4) helm (module3) ----
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get-helm-3
chmod +x /tmp/get-helm-3
/tmp/get-helm-3 || true

# ---- 5) docker + buildx ----
systemctl enable --now docker
usermod -aG docker ec2-user || true
chmod 666 /var/run/docker.sock || true

mkdir -p /usr/libexec/docker/cli-plugins
curl -SL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
  -o /usr/libexec/docker/cli-plugins/docker-buildx
chmod +x /usr/libexec/docker/cli-plugins/docker-buildx

# ---- 6) 2과제 코드 번들 받기 ----
mkdir -p /opt/task2
aws s3 cp "s3://${bucket}/${key}" /tmp/task2.zip --region "${region}"
unzip -o /tmp/task2.zip -d /opt/task2
find /opt/task2 -name "*.sh" -exec chmod +x {} \; || true
chmod -R 777 /opt/task2

# ---- 7) 순차 배포 스크립트 (module1 -> module4 + EKS k8s) ----
cat > /opt/task2/deploy.sh <<'RUN'
#!/bin/bash
# 03/2과제 4개 모듈(멀티 리전)을 순서대로 배포한다.
#   module1 us-east-1      CDN (S3+CloudFront+CF Functions+Lambda@Edge)
#   module2 ap-northeast-2 Keycloak (VPC+ALB+EC2+IAM SAML)
#   module3 ap-northeast-1 Container Logging (EKS) + Helm o11y 스택
#   module4 ap-southeast-1 Workflow (S3+DynamoDB+Lambda+Step Functions)
# 사용: bash /opt/task2/deploy.sh [pin]
set -e
BASE=/opt/task2
PIN="$${1:-${pin}}"
if [ -z "$${PIN:-}" ]; then
  read -rp "비번호 입력: " PIN
fi
echo "[deploy] pin=$PIN"

echo "================= APPLY module1 (CDN, us-east-1) ================="
cd "$BASE/module1"
terraform init -input=false
terraform apply -auto-approve -var "bibunho=$PIN"

echo "================= APPLY module2 (Keycloak, ap-northeast-2) ================="
cd "$BASE/module2"
terraform init -input=false
terraform apply -auto-approve

echo "================= APPLY module3 (Container Logging, ap-northeast-1) ================="
cd "$BASE/module3"
terraform init -input=false
terraform apply -auto-approve
echo "----- module3 EKS k8s/Helm 단계 -----"
export CLUSTER_NAME="$(terraform output -raw cluster_name)"
export REGION="$(terraform output -raw region)"
export MODULE_DIR="$BASE/module3"
bash "$BASE/module3/deploy_k8s.sh"

echo "================= APPLY module4 (Workflow, ap-southeast-1) ================="
cd "$BASE/module4"
terraform init -input=false
terraform apply -auto-approve

echo ""
echo "================= ALL MODULES DEPLOYED ================="
echo "module1: cd $BASE/module1 && terraform output"
echo "module4: cd $BASE/module4 && terraform output"
RUN
chmod +x /opt/task2/deploy.sh

# ---- 8) 완료 마커 ----
touch /opt/task2/READY
echo "BOOTSTRAP COMPLETE"
