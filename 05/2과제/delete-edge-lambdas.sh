#!/bin/bash
# Lambda@Edge(gj2026-cdn-request/response) 삭제 재시도용.
# CloudFront 배포 삭제 후 복제본 drain까지 1~3시간 걸림 → 주기적으로 실행.
# 둘 다 삭제되면 module1(CDN) 재apply 가능.
set +e
ok=0
for fn in gj2026-cdn-request gj2026-cdn-response; do
  if aws lambda get-function --function-name "$fn" --region us-east-1 >/dev/null 2>&1; then
    if aws lambda delete-function --function-name "$fn" --region us-east-1 2>/tmp/err; then
      echo "삭제 OK: $fn"; ok=$((ok+1))
    else
      echo "아직 삭제 불가: $fn ($(cat /tmp/err | head -1))"
    fi
  else
    echo "이미 없음: $fn"; ok=$((ok+1))
  fi
done
[ "$ok" -eq 2 ] && echo ">>> 둘 다 정리됨. 이제 module1 apply 가능: terraform apply -var pin=101 -var alarm_email=<이메일>"
