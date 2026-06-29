#!/bin/bash
# =============================================================================
# Bastion 부트스트랩 (cloud-init user_data) — 2과제(09)
#  - 목적: SSM 접속 후 바로 `bash /opt/task2/deploy.sh` 로 전체 배포가 가능하도록 준비
#  - 흐름: 도구 설치 → S3 에서 2과제 코드 번들 다운로드/해제 → deploy.sh 생성
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

# ---- 3) kubectl ----
curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# ---- 4) helm ----
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

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

# 지급 바이너리/스크립트 실행 권한 + 누구나 작업 가능하도록 권한 개방(임시 bastion)
find /opt/task2 -name '*.sh' -exec chmod +x {} \; || true
chmod -R 777 /opt/task2

# ---- 7) 전체 배포 스크립트 생성 (README per-module 순서를 bash 로 재현) ----
cat > /opt/task2/deploy.sh <<'DEPLOY'
#!/bin/bash
# =============================================================================
# 2과제(09) 전체 배포 — Linux Bastion 에서 실행.
#   순서(README "전체 실행 순서 요약" + Module1 분리 규칙 기준):
#     1) module1        : EKS 클러스터 wsi-eks (ap-northeast-2)  → ACTIVE 대기
#     2) module1/k8s     : KEDA / Karpenter / 매니페스트 (helm·kubectl provider)
#     3) wsi-eks 비공개화 : public endpoint OFF (rubric: Private EKS cluster)
#                          ※ public 은 module1/k8s apply 동안만 ON, 끝나면 닫는다.
#     4) module2         : Container logging (ap-southeast-2)
#                          ※ EKS 는 생성 시점부터 private. 자체 in-VPC bastion 이
#                            S3 setup.sh 를 자동 실행해 Loki/Grafana/ALB 구성.
#     5) module3         : MSK (ap-northeast-3)  — competitor_number 필요
#     6) module4         : REST API (ap-southeast-1)
#
# 사용법:  bash /opt/task2/deploy.sh [competitor_number]
#          (또는)  COMPETITOR_NUMBER=15 bash /opt/task2/deploy.sh
# =============================================================================
exec > >(tee -a /var/log/task2-deploy.log) 2>&1
set -u

ROOT=/opt/task2
COMPETITOR_NUMBER="$${1:-$${COMPETITOR_NUMBER:-${competitor_number}}}"
WSI_REGION=ap-northeast-2
WSI_CLUSTER=wsi-eks

echo "=== Task2(09) deploy 시작 $(date -u) | competitor_number=$COMPETITOR_NUMBER ==="

run_tf () {
  # $1 = 모듈 디렉터리(상대), 이후 인자 = terraform apply 추가 옵션
  dir="$1"; shift
  echo "----- terraform apply: $dir -----"
  if ( cd "$ROOT/$dir" && terraform init -input=false && terraform apply -auto-approve "$@" ); then
    echo "OK: $dir"
  else
    echo "FAIL: $dir (계속 진행)"
  fi
}

# 1) Module1 — EKS 클러스터
run_tf module1

echo "=== wsi-eks ACTIVE 대기 ==="
for i in $(seq 1 90); do
  ST=$(aws eks describe-cluster --name "$WSI_CLUSTER" --region "$WSI_REGION" \
        --query "cluster.status" --output text 2>/dev/null || true)
  echo "wsi-eks status: $ST"
  [ "$ST" = "ACTIVE" ] && break
  sleep 20
done

# 2) Module1/k8s — KEDA/Karpenter/매니페스트 (public endpoint 필요: bastion 은 default VPC)
run_tf module1/k8s

# 3) wsi-eks public endpoint 닫기 → private-only (rubric: Private EKS cluster)
echo "=== wsi-eks public endpoint 닫는 중 (private-only) ==="
CUR=$(aws eks describe-cluster --region "$WSI_REGION" --name "$WSI_CLUSTER" \
       --query "cluster.resourcesVpcConfig.endpointPublicAccess" --output text 2>/dev/null || true)
if [ "$CUR" = "True" ] || [ "$CUR" = "true" ]; then
  aws eks update-cluster-config --region "$WSI_REGION" --name "$WSI_CLUSTER" \
    --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true,publicAccessCidrs=[]
fi
for i in $(seq 1 60); do
  STt=$(aws eks describe-cluster --region "$WSI_REGION" --name "$WSI_CLUSTER" \
         --query "cluster.resourcesVpcConfig.endpointPublicAccess" --output text 2>/dev/null || true)
  if [ "$STt" = "False" ] || [ "$STt" = "false" ]; then
    echo "wsi-eks private-only 적용 완료."
    break
  fi
  sleep 10
done

# 4) Module2 — Container logging (생성 시점부터 private; 자체 bastion 이 setup.sh 실행)
run_tf module2

# 5) Module3 — MSK (competitor_number 필요)
run_tf module3 -var="competitor_number=$COMPETITOR_NUMBER"

# 6) Module4 — REST API
run_tf module4

echo "=== Task2(09) deploy 종료 $(date -u) ==="
echo "NOTE: module2 의 k8s(Loki/Grafana/ALB/Fluent Bit/nginx)는 module2 가 만든"
echo "      in-VPC bastion(wsc2026-logging-bastion) 이 setup.sh 로 자동 구성한다."
echo "      확인: 해당 bastion 에 SSM 접속 후  sudo cat /root/setup_done.txt"
echo "NOTE: module3 토픽 생성/producer 실행은 wsc-app-ec2 에서 README 3장 절차대로 수행."
echo "NOTE: wsi-eks 를 재apply/destroy 하려면 먼저 public 을 다시 켜야 한다:"
echo "      aws eks update-cluster-config --region $WSI_REGION --name $WSI_CLUSTER \\"
echo "        --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true"
DEPLOY

chmod +x /opt/task2/deploy.sh

# ---- 8) 완료 마커 ----
touch /opt/task2/READY
echo "BOOTSTRAP COMPLETE"
