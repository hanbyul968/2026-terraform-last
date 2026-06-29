#!/bin/bash
# Lambda@Edge(gj2026-cdn-request/response) 삭제 재시도 - delete-edge-lambdas.ps1 변환본
# CloudFront 배포 삭제 후 복제본 drain까지 1~3시간. 둘 다 삭제되면 module1 apply 가능.
# 엣지 람다는 반드시 us-east-1 에서 생성/삭제된다 (region 고정 유지).
set -uo pipefail

ok=0
for fn in gj2026-cdn-request gj2026-cdn-response; do
  if ! aws lambda get-function --function-name "$fn" --region us-east-1 >/dev/null 2>&1; then
    echo "이미 없음: $fn"
    ok=$((ok + 1))
    continue
  fi
  if aws lambda delete-function --function-name "$fn" --region us-east-1 2>/dev/null; then
    echo "삭제 OK: $fn"
    ok=$((ok + 1))
  else
    echo "아직 삭제 불가(복제본 drain 대기): $fn"
  fi
done

if [ "$ok" -eq 2 ]; then
  echo ">>> 둘 다 정리됨. 이제 module1 apply 가능: terraform apply -var pin=101 -var alarm_email=<이메일>"
fi
