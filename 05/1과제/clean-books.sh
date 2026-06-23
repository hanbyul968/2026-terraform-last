#!/bin/bash
# books DynamoDB 테이블의 모든 항목을 삭제한다.
# 스펙: "채점 전에 어떠한 데이터 항목이 있어도 안됩니다."
# 채점(mark.sh) 직전에 1회 실행하여 테스트로 쌓인 데이터를 비운다.
#
# 사용: bash clean-books.sh
set -euo pipefail

REGION="${REGION:-ap-northeast-2}"
TABLE="${TABLE:-books}"

echo "=== ${TABLE} 테이블 항목 삭제 (region ${REGION}) ==="
aws dynamodb scan --table-name "$TABLE" --region "$REGION" \
  --projection-expression "booking_id" \
  --query "Items[].booking_id.S" --output text \
| tr '\t' '\n' | while read -r id; do
    [ -n "$id" ] || continue
    aws dynamodb delete-item --table-name "$TABLE" --region "$REGION" \
      --key "{\"booking_id\":{\"S\":\"$id\"}}"
    echo "deleted ${id}"
  done

remaining="$(aws dynamodb scan --table-name "$TABLE" --region "$REGION" --select COUNT --query Count --output text)"
echo "=== 남은 항목 수: ${remaining} (0 이어야 함) ==="
