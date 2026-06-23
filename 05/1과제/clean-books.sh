#!/bin/bash
# 채점(mark.sh) 직전 1회 실행하는 정리 스크립트.
#  1) books DynamoDB 테이블의 모든 항목 삭제
#     - 스펙: "채점 전에 어떠한 데이터 항목이 있어도 안됩니다."
#  2) skills 네임스페이스의 nginx-test 파드 삭제
#     - 4-5(NetworkPolicy) 채점이 nginx-test 를 새로 만드는데, 이전 채점의
#       잔여 파드가 남아 있으면 delete+run 이 꼬여 빈 출력이 난다.
#
# 사용: bash clean-books.sh
set -uo pipefail

REGION="${REGION:-ap-northeast-2}"
TABLE="${TABLE:-books}"

echo "=== ${TABLE} 테이블 항목 삭제 (region ${REGION}) ==="
aws dynamodb scan --table-name "$TABLE" --region "$REGION" \
  --projection-expression "booking_id" \
  --query "Items[].booking_id.S" --output text \
| tr '\t' '\n' | sed 's/[[:space:]]*$//' | while read -r id; do
    [ -n "$id" ] || continue
    aws dynamodb delete-item --table-name "$TABLE" --region "$REGION" \
      --key "{\"booking_id\":{\"S\":\"${id}\"}}" && echo "deleted ${id}"
  done

remaining="$(aws dynamodb scan --table-name "$TABLE" --region "$REGION" --select COUNT --query Count --output text)"
echo "=== 남은 항목 수: ${remaining} (0 이어야 함) ==="

echo "=== skills/nginx-test 잔여 파드 정리 (4-5 대비) ==="
kubectl delete pod nginx-test -n skills --ignore-not-found --wait=true

echo "=== 정리 완료. 이제 mark.sh 실행 가능 ==="
