#!/bin/bash
# =============================================================================
# 2과제(04) 배포 오케스트레이션 — Bastion(Linux)에서 실행: bash /opt/task2/deploy.sh
#   module1 EKS Scaling(ap-ne-2) → module2 VPC Lattice(ap-se-1)
#   → module3 Container logging(ap-ne-1) → module4 REST API(us-east-1)
# =============================================================================
set -euo pipefail
ROOT=/opt/task2
cd "$ROOT"

echo "===== module1: EKS Scaling (ap-northeast-2) ====="
cd "$ROOT/module1"
terraform init -input=false
terraform apply -auto-approve
REGION=ap-northeast-2
CLUSTER=wsc-scaling-cluster
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
KEDA_ROLE=$(terraform output -raw keda_irsa_role_arn)
SQS_URL=$(terraform output -raw sqs_queue_url)

helm repo add kedacore https://kedacore.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install keda kedacore/keda -n keda --create-namespace \
  --set "serviceAccount.operator.annotations.eks\.amazonaws\.com/role-arn=$KEDA_ROLE"

KARP_ROLE=$(terraform output -raw karpenter_irsa_role_arn)
KARP_NODE_ROLE=$(terraform output -raw karpenter_node_role_name)
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter -n kube-system \
  --set "settings.clusterName=$CLUSTER" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$KARP_ROLE" || \
  echo "WARN: karpenter helm install needs a version pin; see manifest/karpenter.yaml"

kubectl create namespace wsc-scaling --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$ROOT/module1/manifest/deployment.yaml"
sed "s|__SQS_URL__|$SQS_URL|g; s|__REGION__|$REGION|g" "$ROOT/module1/manifest/scaledobject.yaml" | kubectl apply -f -
sed "s|__NODE_ROLE__|$KARP_NODE_ROLE|g; s|__CLUSTER__|$CLUSTER|g" "$ROOT/module1/manifest/karpenter.yaml" | kubectl apply -f - || true

echo "===== module2: VPC Lattice (ap-southeast-1) ====="
cd "$ROOT/module2"
terraform init -input=false
terraform apply -auto-approve

echo "===== module3: Container logging (ap-northeast-1) ====="
cd "$ROOT/module3"
terraform init -input=false
terraform apply -auto-approve
aws eks update-kubeconfig --name wsc-logging-cluster --region ap-northeast-1
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl create namespace wsc-logging --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install loki grafana/loki -n wsc-logging -f "$ROOT/module3/manifest/loki-values.yaml"
helm upgrade --install grafana grafana/grafana -n wsc-logging -f "$ROOT/module3/manifest/grafana-values.yaml"
echo "NOTE: app EC2(wsc-logging-app-bastion) docker flask + Fluent Bit 은 Loki NLB 주소 확인 후 SSM 으로 기동"

echo "===== module4: REST API (us-east-1) ====="
cd "$ROOT/module4"
terraform init -input=false
terraform apply -auto-approve

echo "===== ALL MODULES APPLIED ====="
