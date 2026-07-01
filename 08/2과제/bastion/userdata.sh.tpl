#!/bin/bash
# =============================================================================
# Bastion 부트스트랩 (cloud-init user_data) — 2과제(08)
#  - 목적: SSM 접속 후 바로 `bash /opt/task2/deploy.sh <비번호>` 로 전체 배포 가능
#  - 흐름: 도구 설치 → S3 에서 2과제 코드 번들 다운로드/해제 → deploy.sh 생성
#  - 로그: /var/log/bastion-bootstrap.log
#  - 완료 마커: /opt/task2/READY  (이 파일이 보이면 준비 완료)
# =============================================================================
set -eux
exec > /var/log/bastion-bootstrap.log 2>&1

# ---- 1) 기본 도구 ----
dnf install -y git yum-utils unzip tar jq python3 python3-pip

# AWS CLI v2 (AL2023 기본 포함, 없을 경우 대비)
if ! command -v aws >/dev/null 2>&1; then
  curl -SL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi

# ---- 2) terraform ----
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform

# ---- 3) 2과제 코드 번들 받기 ----
mkdir -p /opt/task2
aws s3 cp "s3://${bucket}/${key}" /tmp/task2.zip --region "${region}"
unzip -o /tmp/task2.zip -d /opt/task2

# 지급 스크립트 실행 권한 + 누구나 작업 가능하도록 권한 개방(임시 bastion)
find /opt/task2 -name '*.sh' -exec chmod +x {} \; || true
chmod -R 777 /opt/task2

# ---- 4) 전체 배포 스크립트 생성 ----
cat > /opt/task2/deploy.sh <<'DEPLOY'
#!/bin/bash
# =============================================================================
# 2과제(08) 전체 배포 — Linux Bastion 에서 실행.
#   순서:
#     1) 루트(서버리스 3개: Module1 NoSQL / Module2 CDN / Module3 Workflow)
#         → terraform apply -var team_id=<비번호>
#     2) module4_rds  (Aurora Serverless v2 + Data API + Lambda, ap-northeast-3)
#         → terraform apply
#     3) Module3 Step Functions 실행 → workflow-output 데이터 적재 (채점 3-5)
#     4) Module1 result.json 생성 (채점 1-5)
#
# 사용법:  bash /opt/task2/deploy.sh [비번호]
#          (또는)  TEAM_ID=007 bash /opt/task2/deploy.sh
# =============================================================================
exec > >(tee -a /var/log/task2-deploy.log) 2>&1
set -u

ROOT=/opt/task2
TEAM_ID="$${1:-$${TEAM_ID:-${team_id}}}"
WF_REGION=ap-southeast-1

echo "=== Task2(08) deploy 시작 $(date -u) | team_id=$TEAM_ID ==="

run_tf () {
  # $1 = 루트 디렉터리(상대), 이후 인자 = terraform apply 추가 옵션
  dir="$1"; shift
  echo "----- terraform apply: $dir -----"
  if ( cd "$ROOT/$dir" && terraform init -input=false && terraform apply -auto-approve "$@" ); then
    echo "OK: $dir"
  else
    echo "FAIL: $dir (계속 진행)"
  fi
}

# 1) 루트 — 서버리스 3개 모듈 (Module1/2/3)
run_tf . -var="team_id=$TEAM_ID"

# 2) module4_rds — Aurora Serverless v2 (약 10분 소요)
run_tf module4_rds

# 3) Module3 Step Functions 실행 (채점 3-5 workflow-output 적재)
echo "=== Step Functions 실행 (workflow-state-machine) ==="
SFN_ARN=$(aws stepfunctions list-state-machines --region "$WF_REGION" \
  --query "stateMachines[?name=='workflow-state-machine'].stateMachineArn | [0]" --output text 2>/dev/null || true)
if [ -n "$SFN_ARN" ] && [ "$SFN_ARN" != "None" ]; then
  aws stepfunctions start-execution --region "$WF_REGION" \
    --state-machine-arn "$SFN_ARN" \
    --input "{\"bucket\":\"workflow-input-$TEAM_ID\",\"key\":\"data.csv\"}" || true
  sleep 20
  echo "workflow-output Count:"
  aws dynamodb scan --table-name workflow-output --region "$WF_REGION" --select COUNT || true
else
  echo "WARN: workflow-state-machine 을 찾지 못했습니다 (루트 apply 확인)."
fi

# 4) Module1 result.json 생성 (채점 1-5)
echo "=== result.json 생성 (query.sh electronics) ==="
( cd "$ROOT" && bash files/nosql/query.sh electronics && cat "$HOME/result.json" ) || true

echo "=== Task2(08) deploy 종료 $(date -u) ==="
echo "NOTE: 채점은 CloudShell 에서 grade_module1_v2.sh ~ grade_module4_v2.sh 로 수행."
echo "NOTE: CloudFront 배포/Aurora 기동에 최대 3분 소요될 수 있습니다."
DEPLOY

chmod +x /opt/task2/deploy.sh

# ---- 5) 완료 마커 ----
touch /opt/task2/READY
echo "BOOTSTRAP COMPLETE"
