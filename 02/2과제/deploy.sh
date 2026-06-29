#!/bin/bash
# 2과제(02) 배포 — Bastion 에서: BIBUNHO=<비번호> bash /opt/task2/deploy.sh
#   module1 Workflow(ap-se-1) → module2 Analytics(ap-ne-2) → module3 Event(eu-west-1) → module4 MSK(ap-ne-1)
set -euo pipefail
ROOT=/opt/task2
BIBUNHO="${BIBUNHO:-000}"

echo "===== module1: Student-score Workflow (ap-southeast-1) ====="
cd "$ROOT/module1" && terraform init -input=false && terraform apply -auto-approve -var="bibunho=$BIBUNHO"

echo "===== module2: Real-time analytics (ap-northeast-2) ====="
cd "$ROOT/module2" && terraform init -input=false && terraform apply -auto-approve
echo "NOTE: Managed Flink Studio(wsc2026-analytics-flink) 는 null_resource(CLI)로 생성됨. Zeppelin 노트북 SQL 은 콘솔에서 수행."

echo "===== module3: Cloud event handling (eu-west-1) ====="
cd "$ROOT/module3" && terraform init -input=false && terraform apply -auto-approve
echo "NOTE: SNS(wsc2026-event-alert) 구독(이메일) 후 Confirm 필요."

echo "===== module4: MSK (ap-northeast-1) ====="
cd "$ROOT/module4" && terraform init -input=false && terraform apply -auto-approve -var="bibunho=$BIBUNHO"
echo "NOTE: MSK 토픽(wsc2026-sensor-raw 3/2, wsc2026-sensor-alert 1/2)은 producer EC2(SSM)에서 kafka-topics 로 생성."

echo "===== ALL MODULES APPLIED ====="
