param([string]$Region, [string]$RoleArn, [string]$Account, [string]$Name)
$ErrorActionPreference = "Continue"

$dbarn = "arn:aws:glue:${Region}:${Account}:database/real_time_analytics"
$bucket = "gj2026-flink-deps-$Account"
$jar = "flink-sql-connector-kafka-1.15.4.jar"   # ZEPPELIN-FLINK-3_0 = Flink 1.15

# 0) Kafka 커넥터 jar를 S3에 준비 (Studio 기본엔 kafka 커넥터 없음)
aws s3api create-bucket --bucket $bucket --region $Region --create-bucket-configuration "LocationConstraint=$Region" 2>$null
aws s3api head-object --bucket $bucket --key $jar --region $Region 2>$null
if ($LASTEXITCODE -ne 0) {
  $tmp = Join-Path $env:TEMP $jar
  curl.exe -fsSL -o $tmp "https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/1.15.4/$jar"
  aws s3 cp $tmp "s3://$bucket/$jar" --region $Region 2>$null
}

# 1) 앱 생성 (Kafka 커넥터 custom artifact 포함). 이미 있으면 무시
$cfg = '{"FlinkApplicationConfiguration":{"ParallelismConfiguration":{"ConfigurationType":"CUSTOM","Parallelism":1,"ParallelismPerKPU":1}},"ZeppelinApplicationConfiguration":{"MonitoringConfiguration":{"LogLevel":"INFO"},"CatalogConfiguration":{"GlueDataCatalogConfiguration":{"DatabaseARN":"__DBARN__"}},"CustomArtifactsConfiguration":[{"ArtifactType":"DEPENDENCY_JAR","S3ContentLocation":{"BucketARN":"arn:aws:s3:::__BUCKET__","FileKey":"__JAR__"}}]}}'
$cfg = $cfg.Replace("__DBARN__", $dbarn).Replace("__BUCKET__", $bucket).Replace("__JAR__", $jar)
$f = Join-Path $env:TEMP "gj2026-zeppelin-cfg.json"
$cfg | Out-File -FilePath $f -Encoding ascii

aws kinesisanalyticsv2 create-application `
  --region $Region --application-name $Name `
  --runtime-environment ZEPPELIN-FLINK-3_0 --application-mode INTERACTIVE `
  --service-execution-role $RoleArn --application-configuration "file://$f" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "[INFO] create 생략(이미 존재 가능)" }

# 2) READY면 시작 → RUNNING
$status = aws kinesisanalyticsv2 describe-application --region $Region --application-name $Name --query "ApplicationDetail.ApplicationStatus" --output text 2>$null
Write-Host "[INFO] status=$status"
if ($status -eq "READY") {
  aws kinesisanalyticsv2 start-application --region $Region --application-name $Name 2>$null
  Write-Host "[INFO] start 요청 (RUNNING까지 3~5분)"
}
