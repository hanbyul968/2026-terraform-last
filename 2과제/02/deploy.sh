#!/bin/bash
# 2과제(02) 배포 — Bastion 에서: BIBUNHO=<비번호> bash /opt/task2/deploy.sh
#   module1 Workflow(ap-southeast-1) → module2 Analytics(ap-northeast-2)
#   → module3 Cloud Event(eu-west-1) → module4 MSK(ap-northeast-1)
#
# module3 는 과제지_v8 과 채점기준표_v8 이 서로 다른 리소스를 요구하므로 기준을 선택한다.
#   SPEC=rubric (기본) 채점기준표·채점스크립트(mark2-3.sh) 기준
#   SPEC=task          과제지·배포파일 기준
# 예: BIBUNHO=103 SPEC=task bash /opt/task2/deploy.sh
#
# 참고: module1(순수 서버리스)과 module3(순수 TF)은 로컬 PowerShell 에서도 apply 가능.
#       module2(Flink CLI/null_resource=bash)와 module4(MSK/producer in-VPC)는 Bastion 권장.
set -euo pipefail
ROOT=/opt/task2
if [ -z "${BIBUNHO:-}" ]; then read -rp "비번호(bibunho) 입력: " BIBUNHO; fi
SPEC="${SPEC:-rubric}"
case "$SPEC" in
  task|rubric) ;;
  *) echo "SPEC 은 task 또는 rubric 이어야 합니다 (현재: $SPEC)" >&2; exit 1 ;;
esac
echo "module3 채점 기준: SPEC=$SPEC"

echo "===== module1: Student-score Workflow (ap-southeast-1) ====="
cd "$ROOT/module1" && terraform init -input=false && terraform apply -auto-approve -var="bibunho=$BIBUNHO"
echo "NOTE: 채점 시 배포파일 test.csv 를 s3://wsc2026-student-score-bucket-$BIBUNHO/input/ 에 업로드."

echo "===== module2: Real-time analytics (ap-northeast-2) ====="
cd "$ROOT/module2" && terraform init -input=false && terraform apply -auto-approve
echo "NOTE: EC2(wsc2026-analytics-ec2) 는 user_data 로 app(port 5000) systemd 자동기동."
echo "      Managed Flink Studio(wsc2026-analytics-flink) 는 null_resource(aws CLI)로 생성."
echo "      Flink Notebook SQL 은 콘솔에서 수행."

echo "===== module3: Cloud event handling (eu-west-1) ====="
cd "$ROOT/module3" && terraform init -input=false && terraform apply -auto-approve -var="spec=$SPEC"
echo "NOTE: SNS(wsc2026-event-alert) 이메일 구독 시 Confirm 필요."
if [ "$SPEC" = "rubric" ]; then
  echo "      [rubric] Lambda 6개 + AWS Config(wsc2026-sg-ssh-rule, wsc2026-required-tags-rule) 생성."
  echo "      [rubric] SG 인바운드 0건 + DisableApiStop + rate(1 minute) guard 로 3-4 복구 보장."
else
  echo "      [task] Lambda 4개(sg/role/terminate/type) + 규칙 4개, SG 인바운드 tcp/80, Config 없음."
fi

echo "===== module4: MSK (ap-northeast-1) ====="
cd "$ROOT/module4" && terraform init -input=false && terraform apply -auto-approve -var="bibunho=$BIBUNHO"
echo "NOTE: producer EC2(wsc2026-sensor-producer) 가 MSK ACTIVE 후 토픽 자동 생성+producer 기동."
echo "      (wsc2026-sensor-raw 3/2, wsc2026-sensor-alert 1/2). 확인: SSM 접속 후 /var/log/module4-setup.log"

echo "===== ALL MODULES APPLIED ====="
