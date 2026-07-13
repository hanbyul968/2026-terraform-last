#!/bin/bash
# Managed Apache Flink (Zeppelin Studio) 생성/시작
# Terraform aws provider 가 Zeppelin Studio 미지원 -> AWS CLI 로 생성한다.
# 사용: zeppelin.sh <Region> <RoleArn> <Account> <Name> <GlueDatabaseArn>
set -uo pipefail

REGION="$1"
ROLE_ARN="$2"
ACCOUNT="$3"
NAME="$4"
DBARN="$5"

CFG="/tmp/${NAME}-cfg.json"
jq -n --arg dbarn "$DBARN" '{
  FlinkApplicationConfiguration: {
    ParallelismConfiguration: { ConfigurationType: "CUSTOM", Parallelism: 1, ParallelismPerKPU: 1 }
  },
  ZeppelinApplicationConfiguration: {
    MonitoringConfiguration: { LogLevel: "INFO" },
    CatalogConfiguration: { GlueDataCatalogConfiguration: { DatabaseARN: $dbarn } }
  }
}' > "$CFG"

# Runtime: ZEPPELIN-FLINK-3_0 (= Apache Flink 1.19 studio), Mode: INTERACTIVE
aws kinesisanalyticsv2 create-application \
  --region "$REGION" --application-name "$NAME" \
  --runtime-environment ZEPPELIN-FLINK-3_0 --application-mode INTERACTIVE \
  --service-execution-role "$ROLE_ARN" --application-configuration "file://$CFG" 2>/dev/null \
  || echo "[INFO] create 생략(이미 존재 가능)"

STATUS=$(aws kinesisanalyticsv2 describe-application --region "$REGION" \
  --application-name "$NAME" --query "ApplicationDetail.ApplicationStatus" --output text 2>/dev/null || true)
echo "[INFO] status=$STATUS"
if [ "$STATUS" = "READY" ]; then
  aws kinesisanalyticsv2 start-application --region "$REGION" --application-name "$NAME" 2>/dev/null || true
  echo "[INFO] start 요청 (RUNNING 까지 3~5분)"
fi
