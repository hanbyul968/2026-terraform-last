# Lambda@Edge(gj2026-cdn-request/response) 삭제 재시도 (PowerShell)
# CloudFront 배포 삭제 후 복제본 drain까지 1~3시간. 둘 다 삭제되면 module1 apply 가능.
$ok = 0
foreach ($fn in @("gj2026-cdn-request", "gj2026-cdn-response")) {
  aws lambda get-function --function-name $fn --region us-east-1 *> $null
  if ($LASTEXITCODE -ne 0) { Write-Host "이미 없음: $fn"; $ok++; continue }
  aws lambda delete-function --function-name $fn --region us-east-1 2>$null
  if ($LASTEXITCODE -eq 0) { Write-Host "삭제 OK: $fn"; $ok++ }
  else { Write-Host "아직 삭제 불가(복제본 drain 대기): $fn" }
}
if ($ok -eq 2) { Write-Host ">>> 둘 다 정리됨. 이제 module1 apply 가능: terraform apply -var pin=101 -var alarm_email=<이메일>" }
