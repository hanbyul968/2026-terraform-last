#!/bin/bash
# Managed Apache Flink (Zeppelin Studio) 삭제
# 사용: zeppelin-delete.sh <Region> <Name>
set -uo pipefail
REGION="$1"
NAME="$2"

CT=$(aws kinesisanalyticsv2 describe-application --region "$REGION" \
  --application-name "$NAME" --query "ApplicationDetail.CreateTimestamp" --output text 2>/dev/null || true)
if [ -n "$CT" ] && [ "$CT" != "None" ]; then
  aws kinesisanalyticsv2 stop-application --region "$REGION" --application-name "$NAME" --force 2>/dev/null || true
  sleep 5
  aws kinesisanalyticsv2 delete-application --region "$REGION" \
    --application-name "$NAME" --create-timestamp "$CT" 2>/dev/null || true
fi
