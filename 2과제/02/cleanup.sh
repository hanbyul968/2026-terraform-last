#!/bin/bash
# 2과제(02) 채점 전 데이터 클렌징 — module1(Workflow) 전용
#
# 새 채점기준표 1번 사전준비:
#   "채점 전 S3 버킷과 DynamoDB의 데이터 클렌징이 완료된지 확인하며,
#    클렌징이 안되었다면 1-1과 1-5, 1-6은 틀린 것으로 간주합니다."
#
# 사용: BIBUNHO=102 bash cleanup.sh
#
# ⚠ module3(MSK)의 wsc2026-sensor-data 테이블과 alert 버킷은 지우지 않는다.
#   채점 3-5/3-6 이 데이터가 남아 있어야 정답이다.
set -euo pipefail

BIBUNHO="${BIBUNHO:-102}"
REGION="ap-southeast-1"
BUCKET="wsc2026-student-score-bucket-${BIBUNHO}"
TABLE="wsc2026-student-score"

echo "== S3 클렌징: s3://$BUCKET (region $REGION)"
aws s3 rm "s3://$BUCKET/" --recursive --region "$REGION" >/dev/null 2>&1 || true

echo "== DynamoDB 클렌징: $TABLE"
while :; do
  ITEMS=$(aws dynamodb scan --table-name "$TABLE" --region "$REGION" \
    --projection-expression "studentId,examDate" --query 'Items[*]' --output json)
  COUNT=$(printf '%s' "$ITEMS" | jq 'length')
  [ "$COUNT" -eq 0 ] && break
  printf '%s' "$ITEMS" | jq -c '.[]' | while read -r key; do
    aws dynamodb delete-item --table-name "$TABLE" --region "$REGION" --key "$key" >/dev/null
  done
done

S3_LEFT=$(aws s3api list-objects-v2 --bucket "$BUCKET" --region "$REGION" \
  --query 'length(Contents || `[]`)' --output text 2>/dev/null || echo 0)
DDB_LEFT=$(aws dynamodb scan --table-name "$TABLE" --region "$REGION" --select COUNT --query Count --output text)

echo
echo "S3 objects   : $S3_LEFT (0 이어야 함)"
echo "DynamoDB item: $DDB_LEFT (0 이어야 함)"
if [ "$S3_LEFT" = "0" ] && [ "$DDB_LEFT" = "0" ]; then
  echo "클렌징 완료 — 채점위원이 input/test.csv 업로드 시 워크플로가 자동 실행된다."
else
  echo "클렌징 실패 — 남은 데이터를 확인하세요." >&2
  exit 1
fi
