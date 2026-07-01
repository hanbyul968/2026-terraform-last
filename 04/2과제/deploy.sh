#!/bin/bash
# =============================================================================
# 2과제(04) 배포 오케스트레이션 — Bastion(Linux)에서 실행:
#     bash /opt/task2/deploy.sh [비번호]
#
#   1) module1        : EKS Scaling 인프라 wsc-scaling-cluster (ap-northeast-2)
#   2) (wsc-scaling-cluster ACTIVE 대기)
#   3) module1/k8s    : KEDA / Karpenter / Deployment / ScaledObject (helm+kubectl provider)
#   4) module2        : VPC Lattice (ap-southeast-1) — app EC2 는 flask 자동 기동
#   5) module3        : Container logging (ap-northeast-1)
#                       ※ EKS 생성 후 app EC2(wsc-logging-app-bastion)가 ec2-bootstrap.sh 로
#                          도커 컨테이너(wsc-log-app)+Loki/Grafana(helm)+Fluent Bit 을 자동 구성.
#   6) module4        : REST API (us-east-1) — 순수 서버리스(로컬에서도 apply 가능)
# =============================================================================
exec > >(tee -a /var/log/task2-deploy.log) 2>&1
set -u
ROOT=/opt/task2
NM="${1:-${COMPETITOR_NUMBER:-00}}"
SCALING_REGION=ap-northeast-2
SCALING_CLUSTER=wsc-scaling-cluster

run_tf () {
  dir="$1"; shift
  echo "----- terraform apply: $dir -----"
  if ( cd "$ROOT/$dir" && terraform init -input=false && terraform apply -auto-approve "$@" ); then
    echo "OK: $dir"
  else
    echo "FAIL: $dir (계속 진행)"
  fi
}

echo "===== module1: EKS Scaling (ap-northeast-2) ====="
run_tf module1

echo "===== wsc-scaling-cluster ACTIVE 대기 ====="
for i in $(seq 1 90); do
  ST=$(aws eks describe-cluster --name "$SCALING_CLUSTER" --region "$SCALING_REGION" \
        --query "cluster.status" --output text 2>/dev/null || true)
  echo "status: $ST"
  [ "$ST" = "ACTIVE" ] && break
  sleep 20
done

echo "===== module1/k8s: KEDA / Karpenter / Deployment / ScaledObject ====="
run_tf module1/k8s

echo "===== module2: VPC Lattice (ap-southeast-1) ====="
run_tf module2

echo "===== module3: Container logging (ap-northeast-1) ====="
run_tf module3 -var="competitor_number=$NM"
echo "NOTE: module3 의 컨테이너(wsc-log-app)/Loki/Grafana/Fluent Bit 은 app EC2"
echo "      (wsc-logging-app-bastion)가 ec2-bootstrap.sh 로 자동 구성한다."
echo "      진행 확인: 해당 EC2 에 SSM 접속 후  cat /opt/ec2_ready.txt , cat /tmp/m3_setup_done.txt"

echo "===== module4: REST API (us-east-1) ====="
run_tf module4

echo "===== ALL MODULES APPLIED ====="
echo "NOTE: Grafana admin = wsc2026-admin-$NM / admin$NM!  (module3)"
