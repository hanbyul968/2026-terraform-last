#!/bin/bash
# =============================================================================
# /opt/task2/deploy.sh  (Linux Bastion 에서 실행)
#   2과제 4개 모듈을 README 순서(module1 -> module2 -> module3 -> module4)대로
#   각각 자체 state 로 init + apply 한다. PowerShell 단계는 모두 bash 로 변환됨.
#
#   사용법:  sudo bash /opt/task2/deploy.sh <선수등번호>
#            (인자 생략 시 /opt/task2/.competitor_number 또는 환경변수 number 사용)
#
#   리전 매핑(README):
#     module1 NoSQL            ap-southeast-1
#     module2 CDN Function     us-east-1
#     module3 EKS Scaling      ap-northeast-2  (+ deploy_k8s.sh: KEDA/Karpenter/워크로드)
#     module4 Container Logging ap-northeast-1 (+ manifest/setup.sh: 이미지/Helm/대시보드)
# =============================================================================
set -euo pipefail
exec > >(tee -a /var/log/task2-deploy.log) 2>&1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- 선수등번호 결정 (인자 > 환경변수 number > .competitor_number 파일 > 프롬프트) ----
COMPETITOR_NUMBER="${1:-${number:-}}"
if [ -z "${COMPETITOR_NUMBER}" ] && [ -f "${ROOT}/.competitor_number" ]; then
  COMPETITOR_NUMBER="$(cat "${ROOT}/.competitor_number")"
fi
# 하드코딩 default 제거: 값이 없으면 apply 시점에 입력받는다.
if [ -z "${COMPETITOR_NUMBER:-}" ]; then
  read -rp "비번호(competitor_number) 입력: " COMPETITOR_NUMBER
fi

echo "===== [Task2-06] deploy start (competitor_number=${COMPETITOR_NUMBER}) ====="

# -----------------------------------------------------------------------------
# module1 — NoSQL (ap-southeast-1)
# -----------------------------------------------------------------------------
echo "----- [1/4] module1 (NoSQL, ap-southeast-1) -----"
cd "${ROOT}/module1"
terraform init -input=false -no-color
terraform apply -auto-approve -input=false -no-color

# -----------------------------------------------------------------------------
# module2 — CDN Function (us-east-1)
# -----------------------------------------------------------------------------
echo "----- [2/4] module2 (CDN Function, us-east-1) -----"
cd "${ROOT}/module2"
terraform init -input=false -no-color
terraform apply -auto-approve -input=false -no-color

# -----------------------------------------------------------------------------
# module3 — EKS Scaling (ap-northeast-2)
#   terraform apply: SQS/EKS/NodeGroup/IRSA/ECR/S3(deploy 번들).
#   이후 README 가 module3 apply 의 일부로 설명하는 ECR build/push + k8s 적용을
#   Linux Bastion 에서 직접 수행한다. (deploy_k8s.ps1 -> deploy_k8s.sh 호출)
# -----------------------------------------------------------------------------
echo "----- [3/4] module3 (EKS Scaling, ap-northeast-2) -----"
cd "${ROOT}/module3"
terraform init -input=false -no-color
terraform apply -auto-approve -input=false -no-color

M3_REGION="ap-northeast-2"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

# module3 apply 가 렌더링해 둔 배포 번들(매니페스트 + env.sh) 내려받기
MDIR="${ROOT}/module3/.deploybundle"
mkdir -p "${MDIR}"
aws s3 cp "s3://skm-deploy-${ACCOUNT}/" "${MDIR}/" --recursive --region "${M3_REGION}"

# env.sh: REGION ECR_REPO CLUSTER_NAME CLUSTER_ENDPOINT KEDA_ROLE_ARN KARPENTER_ROLE_ARN (모두 export)
# shellcheck disable=SC1091
source "${MDIR}/env.sh"

# ECR 로그인 + 앱 이미지 빌드/푸시 (README: module3 apply == ECR 빌드/푸시 포함)
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
docker build --platform linux/amd64 -t "${ECR_REPO}:latest" "${MDIR}"
docker push "${ECR_REPO}:latest"

# k8s 단계(KEDA + Karpenter + 매니페스트) — 변환된 deploy_k8s.sh 호출
export MANIFEST_DIR="${MDIR}"
bash "${ROOT}/module3/deploy_k8s.sh"

# -----------------------------------------------------------------------------
# module4 — Container Logging / O11y (ap-northeast-1)
#   1) terraform apply (인프라)  2) manifest/setup.sh (이미지/Helm/워크로드/대시보드)
# -----------------------------------------------------------------------------
echo "----- [4/4] module4 (Container Logging, ap-northeast-1) -----"
cd "${ROOT}/module4"
terraform init -input=false -no-color
terraform apply -auto-approve -input=false -no-color -var="competitor_number=${COMPETITOR_NUMBER}"

cd "${ROOT}/module4/manifest"
number="${COMPETITOR_NUMBER}" bash ./setup.sh

echo "===== [Task2-06] deploy complete ====="
echo "module3:  aws eks update-kubeconfig --name skm-eks-cluster --region ap-northeast-2"
echo "module4:  aws eks update-kubeconfig --name o11y-cluster   --region ap-northeast-1"
