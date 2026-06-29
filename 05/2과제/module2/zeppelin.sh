#!/bin/bash
# Managed Apache Flink (Zeppelin Studio) 생성/시작 - zeppelin.ps1 의 bash 변환본
# 사용: zeppelin.sh <Region> <RoleArn> <Account> <Name>
# $ErrorActionPreference="Continue" 와 동일하게, 개별 명령 실패는 무시하고 진행한다.
set -uo pipefail

REGION="$1"
ROLE_ARN="$2"
ACCOUNT="$3"
NAME="$4"

DBARN="arn:aws:glue:${REGION}:${ACCOUNT}:database/real_time_analytics"
BUCKET="gj2026-flink-deps-${ACCOUNT}"
JAR="flink-sql-connector-kafka-1.15.4.jar" # ZEPPELIN-FLINK-3_0 = Flink 1.15

# 0) Kafka 커넥터 jar를 S3에 준비 (Studio 기본엔 kafka 커넥터 없음)
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration "LocationConstraint=$REGION" 2>/dev/null || true

if ! aws s3api head-object --bucket "$BUCKET" --key "$JAR" --region "$REGION" >/dev/null 2>&1; then
  TMP="/tmp/$JAR"
  curl -fsSL -o "$TMP" "https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-kafka/1.15.4/$JAR"
  aws s3 cp "$TMP" "s3://$BUCKET/$JAR" --region "$REGION" || true
fi

# 1) 앱 생성 (Kafka 커넥터 custom artifact 포함). 이미 있으면 무시
#    중첩 heredoc 없이 jq 로 JSON 구성
CFG="/tmp/gj2026-zeppelin-cfg.json"
jq -n \
  --arg dbarn "$DBARN" \
  --arg barn "arn:aws:s3:::$BUCKET" \
  --arg jar "$JAR" \
  '{
     FlinkApplicationConfiguration: {
       ParallelismConfiguration: { ConfigurationType: "CUSTOM", Parallelism: 1, ParallelismPerKPU: 1 }
     },
     ZeppelinApplicationConfiguration: {
       MonitoringConfiguration: { LogLevel: "INFO" },
       CatalogConfiguration: { GlueDataCatalogConfiguration: { DatabaseARN: $dbarn } },
       CustomArtifactsConfiguration: [
         { ArtifactType: "DEPENDENCY_JAR", S3ContentLocation: { BucketARN: $barn, FileKey: $jar } }
       ]
     }
   }' > "$CFG"

aws kinesisanalyticsv2 create-application \
  --region "$REGION" --application-name "$NAME" \
  --runtime-environment ZEPPELIN-FLINK-3_0 --application-mode INTERACTIVE \
  --service-execution-role "$ROLE_ARN" --application-configuration "file://$CFG" 2>/dev/null \
  || echo "[INFO] create 생략(이미 존재 가능)"

# 2) READY면 시작 → RUNNING
STATUS=$(aws kinesisanalyticsv2 describe-application --region "$REGION" \
  --application-name "$NAME" --query "ApplicationDetail.ApplicationStatus" --output text 2>/dev/null || true)
echo "[INFO] status=$STATUS"
if [ "$STATUS" = "READY" ]; then
  aws kinesisanalyticsv2 start-application --region "$REGION" --application-name "$NAME" 2>/dev/null || true
  echo "[INFO] start 요청 (RUNNING까지 3~5분)"
fi
