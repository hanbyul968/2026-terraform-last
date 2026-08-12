#!/bin/bash
# 07 apply 실행기 — 다른 과제(02/03)와 동일하게 terraform을 foreground로 실행한다.
# systemd-run/journalctl 래핑을 제거하여 apply 진행 로그
# (예: module.VPC.aws_vpc.this: Creating...)가 저널 prefix 없이 그대로 출력된다.
set -Eeuo pipefail
cd /opt/task1
rm -f /opt/task1/TERRAFORM_APPLY_SUCCESS

terraform init -input=false

# 이전 SSM 세션이 리소스 생성 도중 끊겨 state에 기록되지 않은 VPC Origin이
# 이미 Deployed 상태라면 안전하게 import한 뒤 apply를 이어간다.
TF_ADDRESS="module.CloudFront.aws_cloudfront_vpc_origin.alb"
if ! terraform state show "$TF_ADDRESS" >/dev/null 2>&1; then
  VPC_ORIGIN_ID=$(aws cloudfront list-vpc-origins \
    --query "VpcOriginList.Items[?Name=='app-origin'].Id | [0]" \
    --output text 2>/dev/null || true)

  if [ -n "$VPC_ORIGIN_ID" ] && [ "$VPC_ORIGIN_ID" != "None" ]; then
    echo "Found unmanaged VPC Origin: $VPC_ORIGIN_ID"
    for i in $(seq 1 120); do
      STATUS=$(aws cloudfront get-vpc-origin --id "$VPC_ORIGIN_ID" \
        --query "VpcOrigin.Status" --output text 2>/dev/null || echo "Unknown")
      echo "VPC Origin recovery status: $STATUS ($i/120)"
      case "$STATUS" in
        Deployed)
          terraform import -input=false "$TF_ADDRESS" "$VPC_ORIGIN_ID"
          break
          ;;
        Failed|Deleting|Unknown)
          echo "Cannot safely import VPC Origin in status $STATUS." >&2
          exit 1
          ;;
      esac
      sleep 10
    done

    if ! terraform state show "$TF_ADDRESS" >/dev/null 2>&1; then
      echo "VPC Origin did not become Deployed within 20 minutes; inspect it before retrying." >&2
      exit 1
    fi
  fi
fi

terraform apply -input=false -auto-approve

echo ""
echo "================= OUTPUTS ================="
terraform output || true
touch /opt/task1/TERRAFORM_APPLY_SUCCESS
