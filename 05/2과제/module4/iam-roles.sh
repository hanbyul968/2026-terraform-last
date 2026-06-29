#!/bin/bash
# Keycloak 팀별 IAM Role(OIDC web identity) 생성 - iam-roles.ps1 의 bash 변환본
# 사용: iam-roles.sh <InstanceId> <Region> <DevPolicyArn> <SecPolicyArn>
set -uo pipefail

INSTANCE_ID="$1"
REGION="$2"
DEV_POLICY_ARN="$3"
SEC_POLICY_ARN="$4"

IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "$REGION")
ACCT=$(aws sts get-caller-identity --query Account --output text)

OIDC_ARN="arn:aws:iam::${ACCT}:oidc-provider/$IP/realms/team"
OIDC_URL="$IP/realms/team"

make_role() {
  local role="$1" client="$2" policy_arn="$3"
  local tf="/tmp/${role}-trust.json"

  # 중첩 heredoc 없이 jq 로 trust policy 구성 (동적 키: "<ip>/realms/team:aud")
  jq -n \
    --arg fed "$OIDC_ARN" \
    --arg audkey "${OIDC_URL}:aud" \
    --arg client "$client" \
    '{
       Version: "2012-10-17",
       Statement: [
         {
           Effect: "Allow",
           Principal: { Federated: $fed },
           Action: "sts:AssumeRoleWithWebIdentity",
           Condition: { StringEquals: { ($audkey): $client } }
         }
       ]
     }' > "$tf"

  aws iam create-role --role-name "$role" --assume-role-policy-document "file://$tf" 2>/dev/null \
    || aws iam update-assume-role-policy --role-name "$role" --policy-document "file://$tf"
  aws iam attach-role-policy --role-name "$role" --policy-arn "$policy_arn" 2>/dev/null || true
  echo "role $role 구성 완료"
}

make_role "gj2026-keycloak-dev-role" "gj2026-keycloak-dev" "$DEV_POLICY_ARN"
make_role "gj2026-keycloak-sec-role" "gj2026-keycloak-sec" "$SEC_POLICY_ARN"
echo "IAM 역할 생성 완료"
