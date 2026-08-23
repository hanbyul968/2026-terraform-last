#!/bin/bash
# 2과제(02) 배포 — Bastion 에서: BIBUNHO=<비번호> bash /opt/task2/deploy.sh
#   module1 Workflow(ap-southeast-1)
#   module2 Real-time data analytics(ap-northeast-2)
#   module3 MSK(ap-northeast-1)
#
# 과제지 유의사항 12항으로 기존 3번 Cloud Event Handling 과제가 삭제되어
# 4번 MSK 가 3번 항목이 되었다(채점기준표도 동일). 이 저장소도 module3=MSK 구조다.
#
# 참고: module1(순수 서버리스)은 로컬 PowerShell 에서도 apply 가능하지만
#       local-exec 검증 스크립트가 bash 이므로 Bastion 실행을 권장한다.
#       module2(Flink CLI)·module3(MSK/producer in-VPC)는 Bastion 필수.
set -euo pipefail
ROOT=/opt/task2
if [ -z "${BIBUNHO:-}" ]; then read -rp "비번호(bibunho) 입력: " BIBUNHO; fi
echo "BIBUNHO=$BIBUNHO"

echo "===== module1: Student-score Workflow (ap-southeast-1) ====="
cd "$ROOT/module1" && terraform init -input=false && terraform apply -auto-approve -var="bibunho=$BIBUNHO"
echo "NOTE: apply 마지막 단계에서 test.csv 로 워크플로를 1회 검증한 뒤"
echo "      S3 버킷·DynamoDB 를 자동 클렌징한다(채점 조건). 재클렌징은 BIBUNHO=$BIBUNHO bash $ROOT/cleanup.sh"

echo "===== module2: Real-time data analytics (ap-northeast-2) ====="
cd "$ROOT/module2" && terraform init -input=false && terraform apply -auto-approve
echo "NOTE: EC2(wsc2026-analytics-ec2) 는 user_data 로 app(port 5000) systemd 자동기동."
echo "      Managed Flink Studio(wsc2026-analytics-flink) 는 null_resource(aws CLI)로 생성(READY 상태 유지)."
echo "      Flink Notebook SQL 2종은 콘솔에서 직접 실행."

echo "===== module3: MSK (ap-northeast-1) ====="
cd "$ROOT/module3" && terraform init -input=false && terraform apply -auto-approve -var="bibunho=$BIBUNHO"
echo "NOTE: producer EC2(wsc2026-sensor-producer) 가 MSK ACTIVE 후 토픽 자동 생성+producer 기동."
echo "      (wsc2026-sensor-raw 3/2, wsc2026-sensor-alert 1/2). 확인: SSM 접속 후 /var/log/module3-bootstrap.log"

echo "===== ALL MODULES APPLIED ====="
echo "채점 자기검증: number=$BIBUNHO bash $ROOT/mark1.sh / mark2.sh / mark3.sh"
