#!/bin/bash
# =============================================================================
# Bastion 부트스트랩 (cloud-init user_data)
#  - 목적: SSM 접속 후 바로 main terraform apply 가 가능하도록 모든 것을 자동 준비
#  - 흐름: 도구 설치 → S3에서 1과제 코드 번들 다운로드/해제 → runner 생성
#  - 로그: /var/log/bastion-bootstrap.log
#  - 완료 마커: /opt/task1/READY  (이 파일이 보이면 준비 완료)
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

# ---- 3) kubectl (k8s/helm provider 인증 디버깅용; 적용 자체는 provider 가 수행) ----
curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# ---- 4) docker + buildx (main ecr.tf 가 docker build 사용) ----
systemctl enable --now docker
usermod -aG docker ec2-user || true
# SSM 접속 사용자(ssm-user)가 부팅 시점에 아직 없을 수 있어, 임시 bastion 한정으로
# docker 소켓을 개방해 누구나 docker 사용 가능하게 한다.
chmod 666 /var/run/docker.sock || true

mkdir -p /usr/libexec/docker/cli-plugins
curl -SL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
  -o /usr/libexec/docker/cli-plugins/docker-buildx
chmod +x /usr/libexec/docker/cli-plugins/docker-buildx

# ---- 5) 1과제 코드 번들 받기 (terraform 이 로컬 현재 파일을 S3 로 업로드해 둠) ----
mkdir -p /opt/task1
aws s3 cp "s3://${bucket}/${key}" /tmp/task1.zip --region "${region}"
unzip -o /tmp/task1.zip -d /opt/task1

# 지급 바이너리 실행 권한 + 누구나 작업 가능하도록 권한 개방(임시 bastion)
chmod +x /opt/task1/files/book || true
chmod -R 777 /opt/task1

# ---- 6) 원클릭 실행 스크립트 ----
cat > /opt/task1/run.sh <<'RUN'
#!/bin/bash
set -e
# 비번호 입력 (고정값 없음): 환경변수 BIBUNHO 사용하거나, 없으면 프롬프트
if [ -z "$BIBUNHO" ]; then read -rp "비번호(competitor_number) 입력: " BIBUNHO; fi
# 채점(CloudShell VPC)에서 사용할 IAM 신원 ARN -> EKS ClusterAdmin access entry 자동 생성.
#   클러스터 생성자(bastion 역할)만 자동 admin 이므로, 채점 콘솔 신원을 반드시 넣어야 kubectl 채점(5-3/5-4/7-1/7-2)이 됨.
#   계정ID 하드코딩 없음: 대회날 계정이 바뀌면 그 계정의 신원 ARN(예: arn:aws:iam::<acct>:user/<name>)을 입력.
#   모르면 Enter 로 생략 가능(이 경우 채점 전 access entry 를 별도로 추가해야 함).
if [ -z "$GRADER" ]; then read -rp "채점 IAM principal ARN (CloudShell 로그인 신원, 생략 Enter): " GRADER; fi
# 1단계 (AWS 레이어): VPC/KMS/S3/CloudFront/ECR(빌드)/DynamoDB+Backup/EKS/노드그룹/ALB/IAM
cd /opt/task1
terraform init -input=false
terraform apply -auto-approve -var="competitor_number=$BIBUNHO" -var="grader_principal_arn=$GRADER"
# 2단계 (k8s/helm 레이어): book StatefulSet/Service, AWS LB Controller, kube-prometheus-stack,
#   TargetGroupBinding, 그리고 마지막에 EKS public->private 전환(finalize)
cd /opt/task1/k8s
terraform init -input=false
terraform apply -auto-approve
echo ""
echo "================= OUTPUTS ================="
cd /opt/task1 && terraform output || true
RUN
chmod +x /opt/task1/run.sh

# ---- 7) prometheus 상시 포트포워딩 (브라우저로 bastion:9090 접속) ----
# 클러스터/prometheus 가 준비될 때까지 재시도하며 0.0.0.0:9090 으로 계속 포워딩한다.
# (root 인스턴스프로파일=admin=클러스터 생성자라 kubeconfig 인증이 항상 성공)
cat > /usr/local/bin/prom-portforward.sh <<'PF'
#!/bin/bash
export KUBECONFIG=/root/.kube/config
SVC=prometheus-kube-prometheus-prometheus
while true; do
  aws eks update-kubeconfig --region __REGION__ --name wsc-eks-cluster >/dev/null 2>&1
  if kubectl get svc -n prometheus "$SVC" >/dev/null 2>&1; then
    kubectl -n prometheus port-forward --address 0.0.0.0 "svc/$SVC" 9090:9090 || true
  fi
  sleep 10
done
PF
sed -i "s/__REGION__/${region}/g" /usr/local/bin/prom-portforward.sh
chmod +x /usr/local/bin/prom-portforward.sh

cat > /etc/systemd/system/prom-pf.service <<'UNIT'
[Unit]
Description=Persistent kubectl port-forward for Prometheus (0.0.0.0:9090)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/prom-portforward.sh
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now prom-pf.service

# ---- 8) 완료 마커 ----
touch /opt/task1/READY
echo "BOOTSTRAP COMPLETE"
