#!/bin/bash
# 2과제(02) 배포 — Bastion 에서: BIBUNHO=<비번호> bash /opt/task2/deploy.sh
#   module1 Workflow(ap-southeast-1) → module2 Analytics(ap-northeast-2)
#   → module3 Cloud Event(eu-west-1) → module4 MSK(ap-northeast-1)
#
# 참고: module1(순수 서버리스)과 module3(순수 TF)은 로컬 PowerShell 에서도 apply 가능.
#       module2(Flink CLI/null_resource=bash)와 module4(MSK/producer in-VPC)는 Bastion 권장.
set -euo pipefail
ROOT=/opt/task2
if [ -z "${BIBUNHO:-}" ]; then read -rp "비번호(bibunho) 입력: " BIBUNHO; fi

echo "===== module1: Student-score Workflow (ap-southeast-1) ====="
cd "$ROOT/module1" && terraform init -input=false && terraform apply -auto-approve -var="bibunho=$BIBUNHO"
echo "NOTE: 채점 시 배포파일 test.csv 를 s3://wsc2026-student-score-bucket-$BIBUNHO/input/ 에 업로드."

echo "===== module2: Real-time analytics (ap-northeast-2) ====="
cd "$ROOT/module2" && terraform init -input=false && terraform apply -auto-approve
echo "NOTE: EC2(wsc2026-analytics-ec2) 는 user_data 로 app(port 5000) systemd 자동기동."
echo "      Managed Flink Studio(wsc2026-analytics-flink) 는 null_resource(aws CLI)로 생성."
echo "      Flink Notebook SQL 은 콘솔에서 수행."

echo "===== module3: Cloud event handling (eu-west-1) ====="
cd "$ROOT/module3" && terraform init -input=false && terraform apply -auto-approve
echo "NOTE: SNS(wsc2026-event-alert) 이메일 구독 시 Confirm 필요."
echo "      AWS Config recorder/2 rules(wsc2026-sg-ssh-rule, wsc2026-required-tags-rule) 생성."
echo "      SG 인바운드 추가→sg-remediation 회수, EC2 중지→ec2-stop-remediation 재기동."

echo "===== module4: MSK (ap-northeast-1) ====="
cd "$ROOT/module4" && terraform init -input=false && terraform apply -auto-approve -var="bibunho=$BIBUNHO"
echo "NOTE: producer EC2(wsc2026-sensor-producer) 가 MSK ACTIVE 후 토픽 자동 생성+producer 기동."
echo "      (wsc2026-sensor-raw 3/2, wsc2026-sensor-alert 1/2). 확인: SSM 접속 후 /var/log/module4-setup.log"

echo "===== ALL MODULES APPLIED ====="
