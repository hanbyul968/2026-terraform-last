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

# 새 계정 단일 배포용: module state 는 S3 에 둔다(Bastion 재생성 시 유실 방지).
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

# ---- terraform 원격 state 위치 (user_data 가 기록) ----
STATE_BUCKET="${STATE_BUCKET:-}"
if [ -z "${STATE_BUCKET}" ] && [ -f "${ROOT}/.state_bucket" ]; then
  STATE_BUCKET="$(tr -d ' \r\n' < "${ROOT}/.state_bucket")"
fi
STATE_REGION="${STATE_REGION:-}"
if [ -z "${STATE_REGION}" ] && [ -f "${ROOT}/.state_region" ]; then
  STATE_REGION="$(tr -d ' \r\n' < "${ROOT}/.state_region")"
fi
STATE_REGION="${STATE_REGION:-ap-northeast-2}"

if [ -z "${STATE_BUCKET}" ]; then
  echo "ERROR: state 버킷을 알 수 없습니다." >&2
  echo "  bastion 스택을 최신 코드로 apply 했는지 확인하거나, 다음처럼 지정하세요:" >&2
  echo "  STATE_BUCKET=<player_id>-task2-06-tfstate-${ACCOUNT} sudo -E bash $0 ${COMPETITOR_NUMBER}" >&2
  exit 1
fi
echo "state: s3://${STATE_BUCKET} (region ${STATE_REGION})"

# module 별로 S3 원격 state 를 붙여 init 한다.
# 로컬 state 를 쓰면 Bastion 재생성 시 state 가 사라져, 이미 존재하는 리소스를
# 다시 create 하려다 409/EntityAlreadyExists 로 실패한다.
tinit() {
  local mod="$1"
  terraform init -input=false -no-color -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="key=state/${mod}.tfstate" \
    -backend-config="region=${STATE_REGION}"
}

# -----------------------------------------------------------------------------
# module1 — NoSQL (ap-southeast-1)
# -----------------------------------------------------------------------------
echo "----- [1/4] module1 (NoSQL, ap-southeast-1) -----"
cd "${ROOT}/module1"
tinit module1
terraform apply -auto-approve -input=false -no-color

# -----------------------------------------------------------------------------
# module2 — CDN Function (us-east-1)
# -----------------------------------------------------------------------------
echo "----- [2/4] module2 (CDN Function, us-east-1) -----"
cd "${ROOT}/module2"
tinit module2
terraform apply -auto-approve -input=false -no-color

# -----------------------------------------------------------------------------
# module3 — EKS Scaling (ap-northeast-2)
#   terraform apply: SQS/EKS/NodeGroup/IRSA/ECR/S3(deploy 번들).
#   이후 README 가 module3 apply 의 일부로 설명하는 ECR build/push + k8s 적용을
#   Linux Bastion 에서 직접 수행한다. (deploy_k8s.ps1 -> deploy_k8s.sh 호출)
# -----------------------------------------------------------------------------
echo "----- [3/4] module3 (EKS Scaling, ap-northeast-2) -----"
cd "${ROOT}/module3"
tinit module3
terraform apply -auto-approve -input=false -no-color

M3_REGION="ap-northeast-2"

# module3 apply 가 렌더링해 둔 배포 번들(매니페스트 + env.sh) 내려받기
MDIR="${ROOT}/module3/.deploybundle"
mkdir -p "${MDIR}"
aws s3 cp "s3://skm-deploy-${ACCOUNT}/" "${MDIR}/" --recursive --region "${M3_REGION}"

# CRLF 방지: 번들이 Windows(CRLF)에서 렌더링됐을 수 있으므로 LF 로 정규화한다.
# (env.sh 가 CRLF 면 source 시 REGION="...\r" 가 되어 aws/docker 로그인이 깨짐)
find "${MDIR}" -type f \( -name '*.sh' -o -name '*.yaml' \) -exec sed -i 's/\r$//' {} +
sed -i 's/\r$//' "${MDIR}/env.sh"

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
tinit module4
terraform apply -auto-approve -input=false -no-color -var="competitor_number=${COMPETITOR_NUMBER}"

cd "${ROOT}/module4/manifest"
number="${COMPETITOR_NUMBER}" bash ./setup.sh

echo "===== [Task2-06] deploy complete ====="
echo "module3:  aws eks update-kubeconfig --name skm-eks-cluster --region ap-northeast-2"
echo "module4:  aws eks update-kubeconfig --name o11y-cluster   --region ap-northeast-1"
