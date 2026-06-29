#!/bin/bash
# Zeppelin Studio 삭제 - zeppelin-delete.ps1 의 bash 변환본
# 사용: zeppelin-delete.sh <Region> <Name>
set -uo pipefail

REGION="$1"
NAME="$2"

TS=$(aws kinesisanalyticsv2 describe-application --region "$REGION" \
  --application-name "$NAME" --query 'ApplicationDetail.CreateTimestamp' --output text 2>/dev/null || true)

if [ -n "$TS" ] && [ "$TS" != "None" ]; then
  aws kinesisanalyticsv2 delete-application --region "$REGION" \
    --application-name "$NAME" --create-timestamp "$TS"
fi
