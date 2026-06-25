param([string]$Region, [string]$RoleArn, [string]$Account, [string]$Name)
$ErrorActionPreference = "Continue"

$dbarn = "arn:aws:glue:${Region}:${Account}:database/real_time_analytics"
$cfg = '{"FlinkApplicationConfiguration":{"ParallelismConfiguration":{"ConfigurationType":"CUSTOM","Parallelism":1,"ParallelismPerKPU":1}},"ZeppelinApplicationConfiguration":{"MonitoringConfiguration":{"LogLevel":"INFO"},"CatalogConfiguration":{"GlueDataCatalogConfiguration":{"DatabaseARN":"__DBARN__"}}}}'
$cfg = $cfg.Replace("__DBARN__", $dbarn)

$f = Join-Path $env:TEMP "gj2026-zeppelin-cfg.json"
$cfg | Out-File -FilePath $f -Encoding ascii

# 1) 앱 생성 (이미 있으면 무시)
aws kinesisanalyticsv2 create-application `
  --region $Region `
  --application-name $Name `
  --runtime-environment ZEPPELIN-FLINK-3_0 `
  --application-mode INTERACTIVE `
  --service-execution-role $RoleArn `
  --application-configuration "file://$f" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[INFO] create 생략(이미 존재 가능)" }

# 2) 상태가 READY면 시작 → RUNNING (노트북 사용 가능 상태로)
$status = aws kinesisanalyticsv2 describe-application --region $Region --application-name $Name --query "ApplicationDetail.ApplicationStatus" --output text 2>$null
Write-Host "[INFO] status=$status"
if ($status -eq "READY") {
  aws kinesisanalyticsv2 start-application --region $Region --application-name $Name 2>$null
  Write-Host "[INFO] start 요청 (RUNNING까지 3~5분)"
}
