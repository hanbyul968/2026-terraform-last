#!/bin/bash
# Keycloak OIDC Provider 등록 - oidc.ps1 의 bash 변환본
# 사용: oidc.sh <InstanceId> <Region>
# HTTPS(443) self-signed 인증서의 SHA1 thumbprint 를 openssl 로 추출한다.
set -uo pipefail

INSTANCE_ID="$1"
REGION="$2"

IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "$REGION")
echo "Keycloak IP: $IP"

get_thumb() {
  local host="$1"
  echo | openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null \
    | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
    | sed 's/.*=//; s/://g' \
    | tr '[:upper:]' '[:lower:]'
}

THUMB=""
for i in $(seq 1 60); do
  THUMB=$(get_thumb "$IP")
  if [ -n "$THUMB" ]; then
    echo "Thumbprint: $THUMB (시도 $i)"
    break
  fi
  echo "  HTTPS 대기 중... ($i/60)"
  sleep 10
done

if [ -z "$THUMB" ]; then
  echo "ERROR: HTTPS 인증서를 가져오지 못했습니다."
  exit 1
fi

EXISTING=$(aws iam list-open-id-connect-providers \
  --query 'OpenIDConnectProviderList[*].Arn' --output text 2>/dev/null | grep "$IP/realms/team" || true)

if [ -z "$EXISTING" ]; then
  aws iam create-open-id-connect-provider \
    --url "https://$IP/realms/team" \
    --client-id-list gj2026-keycloak-dev gj2026-keycloak-sec \
    --thumbprint-list "$THUMB"
  echo "OIDC Provider 생성 완료"
else
  echo "OIDC Provider 이미 존재"
fi
