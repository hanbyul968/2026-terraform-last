#!/bin/bash
# =============================================================================
# wsc2026 Keycloak SAML -> AWS IAM 연동 (Keycloak 기동 후 실행)
#   1) ALB 경유 Keycloak Realm SAML 메타데이터(descriptor) 수신
#   2) IAM SAML Identity Provider(wsc2026-keycloak-idp) 등록/갱신
#   3) IAM Role(dev/infra) 생성 + 신뢰정책(SAML federation) + 관리형 정책 연결
#
# 사용: bash saml-iam.sh <ALB_DNS> <ACCOUNT_ID> <DEV_POLICY_ARN> <INFRA_POLICY_ARN> \
#                        <REGION> <PROVIDER_NAME> <DEV_ROLE> <INFRA_ROLE>
# =============================================================================
set -euo pipefail

ALB_DNS="$1"
ACCOUNT_ID="$2"
DEV_POLICY="$3"
INFRA_POLICY="$4"
REGION="$5"
PROVIDER="$6"
DEV_ROLE="$7"
INFRA_ROLE="$8"

URL="http://$ALB_DNS/realms/wsc2026-aws/protocol/saml/descriptor"
echo "[saml] waiting for Keycloak SAML descriptor: $URL"
for i in $(seq 1 90); do
  if curl -sf "$URL" -o /tmp/saml-metadata.xml && grep -q "EntityDescriptor" /tmp/saml-metadata.xml; then
    echo "[saml] descriptor fetched"
    break
  fi
  sleep 10
done

ARN="arn:aws:iam::${ACCOUNT_ID}:saml-provider/${PROVIDER}"
if aws iam get-saml-provider --saml-provider-arn "$ARN" >/dev/null 2>&1; then
  aws iam update-saml-provider --saml-provider-arn "$ARN" --saml-metadata-document "file:///tmp/saml-metadata.xml"
else
  aws iam create-saml-provider --name "$PROVIDER" --saml-metadata-document "file:///tmp/saml-metadata.xml"
fi

cat > /tmp/saml-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "$ARN" },
    "Action": "sts:AssumeRoleWithSAML",
    "Condition": { "StringEquals": { "SAML:aud": "https://signin.aws.amazon.com/saml" } }
  }]
}
EOF

create_role() {
  local ROLE="$1" POLICY="$2"
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document "file:///tmp/saml-trust.json" \
    --max-session-duration 3600 2>/dev/null || \
  aws iam update-assume-role-policy --role-name "$ROLE" \
    --policy-document "file:///tmp/saml-trust.json"
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn "$POLICY"
}

create_role "$DEV_ROLE" "$DEV_POLICY"
create_role "$INFRA_ROLE" "$INFRA_POLICY"

echo "[saml] SAML provider + IAM roles configured"
