param([string]$Region, [string]$RoleArn, [string]$Account, [string]$Name)
$ErrorActionPreference = "Continue"

$dbarn = "arn:aws:glue:${Region}:${Account}:database/real_time_analytics"
$cfg = '{"FlinkApplicationConfiguration":{"ParallelismConfiguration":{"ConfigurationType":"CUSTOM","Parallelism":1,"ParallelismPerKPU":1}},"ZeppelinApplicationConfiguration":{"MonitoringConfiguration":{"LogLevel":"INFO"},"CatalogConfiguration":{"GlueDataCatalogConfiguration":{"DatabaseARN":"__DBARN__"}}}}'
$cfg = $cfg.Replace("__DBARN__", $dbarn)

$f = Join-Path $env:TEMP "gj2026-zeppelin-cfg.json"
$cfg | Out-File -FilePath $f -Encoding ascii

aws kinesisanalyticsv2 create-application `
  --region $Region `
  --application-name $Name `
  --runtime-environment ZEPPELIN-FLINK-3_0 `
  --application-mode INTERACTIVE `
  --service-execution-role $RoleArn `
  --application-configuration "file://$f"

if ($LASTEXITCODE -ne 0) { Write-Host "[WARN] create-application 실패 (이미 존재 가능)" }
