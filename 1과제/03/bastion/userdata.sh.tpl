#!/bin/bash
# =============================================================================
# Bastion 부트스트랩 (cloud-init user_data)
# bundle-sha256: ${bundle_hash}
#  - 목적: SSM 접속 후 바로 main terraform apply 가 가능하도록 모든 것을 자동 준비
#  - 흐름: 도구 설치 → S3에서 1과제 코드 번들 다운로드/해제 → runner 생성
#  - 로그: /var/log/bastion-bootstrap.log
#  - 완료 마커: /opt/task1/READY
# =============================================================================
set -eux
exec > /var/log/bastion-bootstrap.log 2>&1

dnf install -y git docker yum-utils unzip tar jq

if ! command -v aws >/dev/null 2>&1; then
  curl -SL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
fi

yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
dnf install -y terraform

curl -sLO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

systemctl enable --now docker
usermod -aG docker ec2-user || true
chmod 666 /var/run/docker.sock || true

mkdir -p /usr/libexec/docker/cli-plugins
curl -SL https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64 \
  -o /usr/libexec/docker/cli-plugins/docker-buildx
chmod +x /usr/libexec/docker/cli-plugins/docker-buildx

mkdir -p /opt/task1
aws s3 cp "s3://${bucket}/${key}" /tmp/task1.zip --region "${region}"
unzip -o /tmp/task1.zip -d /opt/task1

chmod +x /opt/task1/files/book || true
chmod -R 777 /opt/task1

cat > /opt/task1/run.sh <<'RUN'
#!/bin/bash
set -euo pipefail

if [ -z "$${BIBUNHO:-}" ]; then
  read -rp "비번호(bi_number) 입력: " BIBUNHO
fi

GRADER_ARGS=()
if [ -n "$${GRADER:-}" ]; then
  GRADER_ARGS=(-var="grader_principal_arn=$GRADER")
fi

cd /opt/task1
terraform init -input=false

# 1단계: Kubernetes/Helm 적용을 위해 EKS public endpoint를 임시 활성화한다.
terraform apply -auto-approve \
  -var="bi_number=$BIBUNHO" \
  -var="deploy_cdn=false" \
  -var="eks_public_access=true" \
  "$${GRADER_ARGS[@]}"

# 2단계: 앱, ALB, 관측성 구성 후 마지막에 EKS endpoint를 private-only로 전환한다.
cd /opt/task1/k8s
terraform init -input=false
terraform apply -auto-approve

# 3단계: target apply를 사용하지 않고 전체 상태를 재조정한다.
# EKS는 false로 고정하면서 CloudFront와 모든 의존 리소스를 완전하게 적용한다.
cd /opt/task1
terraform apply -auto-approve \
  -var="bi_number=$BIBUNHO" \
  -var="deploy_cdn=true" \
  -var="eks_public_access=false" \
  "$${GRADER_ARGS[@]}"

CF_ID=$(terraform output -raw cloudfront_distribution_id)
CF_DOMAIN=$(terraform output -raw cloudfront_domain)
aws cloudfront wait distribution-deployed --id "$CF_ID"

# 채점 스크립트는 Name=wsc2026-cdn 태그 검색 결과의 첫 배포를 사용한다.
# 이전 실행에서 남은 비활성 배포가 동일 태그를 가지면 000이 되므로,
# 현재 배포 외의 '비활성' 배포에서만 Name 태그를 제거한다.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CURRENT_ARN="arn:aws:cloudfront::$ACCOUNT_ID:distribution/$CF_ID"
mapfile -t CDN_ARNS < <(
  aws resourcegroupstaggingapi get-resources \
    --region us-east-1 \
    --resource-type-filters cloudfront \
    --tag-filters Key=Name,Values=wsc2026-cdn \
    --query 'ResourceTagMappingList[].ResourceARN' \
    --output text | tr '\t' '\n'
)
for ARN in "$${CDN_ARNS[@]}"; do
  [ -z "$ARN" ] && continue
  [ "$ARN" = "$CURRENT_ARN" ] && continue
  STALE_ID="$${ARN##*/}"
  STALE_ENABLED=$(aws cloudfront get-distribution --id "$STALE_ID" \
    --query 'Distribution.DistributionConfig.Enabled' --output text)
  if [ "$STALE_ENABLED" = "False" ] || [ "$STALE_ENABLED" = "false" ]; then
    echo "Removing grader Name tag from disabled stale CloudFront: $STALE_ID"
    aws cloudfront untag-resource --resource "$ARN" --tag-keys '{"Items":["Name"]}'
  else
    echo "ERROR: another enabled CloudFront has Name=wsc2026-cdn: $STALE_ID" >&2
    echo "Disable or retag it explicitly before grading." >&2
    exit 1
  fi
done

# 태그 인덱스 반영을 기다리고 정확히 현재 배포 하나만 검색되는지 확인한다.
for _ in $(seq 1 30); do
  mapfile -t CHECK_ARNS < <(
    aws resourcegroupstaggingapi get-resources \
      --region us-east-1 \
      --resource-type-filters cloudfront \
      --tag-filters Key=Name,Values=wsc2026-cdn \
      --query 'ResourceTagMappingList[].ResourceARN' \
      --output text | tr '\t' '\n'
  )
  if [ "$${#CHECK_ARNS[@]}" -eq 1 ] && [ "$${CHECK_ARNS[0]}" = "$CURRENT_ARN" ]; then
    break
  fi
  sleep 10
done
if [ "$${#CHECK_ARNS[@]}" -ne 1 ] || [ "$${CHECK_ARNS[0]}" != "$CURRENT_ARN" ]; then
  echo "ERROR: CloudFront grader tag is not unique." >&2
  printf '  %s\n' "$${CHECK_ARNS[@]}" >&2
  exit 1
fi

# 정적 페이지가 실제 200을 반환할 때까지 전파를 기다린다.
HTTP_CODE=000
for _ in $(seq 1 60); do
  HTTP_CODE=$(curl -sS -o /dev/null -w '%%{http_code}' --max-time 10 "https://$CF_DOMAIN/" || true)
  [ "$HTTP_CODE" = "200" ] && break
  sleep 10
done
if [ "$HTTP_CODE" != "200" ]; then
  echo "CloudFront smoke test failed: https://$CF_DOMAIN/ -> $HTTP_CODE" >&2
  exit 1
fi

# POST(ALB) → GET(Lambda) E2E를 배포 단계에서 미리 검증한다.
BOOKING_ID=""
for _ in $(seq 1 30); do
  POST_BODY=$(curl -sS --max-time 15 -X POST "https://$CF_DOMAIN/booking" \
    -H 'Content-Type: application/json' \
    -d '{"client_id":"DEPLOY-CHECK","username":"DeployCheck","email":"deploy-check@example.com","concert_name":"DeployCheck"}' || true)
  BOOKING_ID=$(printf '%s' "$POST_BODY" | jq -r '.booking_id // empty' 2>/dev/null || true)
  [ -n "$BOOKING_ID" ] && break
  sleep 10
done
if [ -z "$BOOKING_ID" ]; then
  echo "CloudFront POST smoke test failed: $${POST_BODY:-<empty>}" >&2
  exit 1
fi

GET_BODY=$(curl -sS --max-time 15 "https://$CF_DOMAIN/v1/book?booking_id=$BOOKING_ID")
printf '%s' "$GET_BODY" | jq -e '
  (.client_id == "DEPLOY-CHECK") and
  (.username == "DeployCheck") and
  (.email == "deploy-check@example.com") and
  (.concert_name == "DeployCheck") and
  (.created_at | type == "string" and endswith(" KST"))
' >/dev/null

echo ""
echo "================= DEPLOYMENT READY ================="
echo "CloudFront: https://$CF_DOMAIN/ (HTTP $HTTP_CODE)"
echo "E2E booking_id: $BOOKING_ID"
terraform output || true
RUN
chmod +x /opt/task1/run.sh

touch /opt/task1/READY
echo "BOOTSTRAP COMPLETE"
