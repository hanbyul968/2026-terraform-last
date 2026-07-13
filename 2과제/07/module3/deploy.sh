#!/bin/bash
# module3 EKS Scaling 배포 — Bastion 에서 실행 (sudo bash /opt/deploy/deploy.sh)
# terraform 이 렌더링한 /opt/deploy/env.sh 의 값으로 동작한다.
set -euo pipefail

cd /opt/deploy
source /opt/deploy/env.sh

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

echo "=== [1/5] ECR 로그인 + 이미지 빌드/푸시 ==="
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
docker build --platform linux/amd64 -t "${ECR_REPO}:latest" /opt/deploy
docker push "${ECR_REPO}:latest"

echo "=== [2/5] kubeconfig 연결 ==="
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "=== [3/5] KEDA 설치 ==="
helm repo add kedacore https://kedacore.github.io/charts >/dev/null
helm repo update kedacore >/dev/null
helm upgrade --install keda kedacore/keda -n keda --create-namespace \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KEDA_ROLE_ARN}" \
  --set "tolerations[0].key=dedicated" \
  --set "tolerations[0].value=addon" \
  --set "tolerations[0].effect=NoSchedule" \
  --wait --timeout 10m

echo "=== [4/5] Karpenter 설치 ==="
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter -n kube-system \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_ROLE_ARN}" \
  --set "tolerations[0].key=dedicated" \
  --set "tolerations[0].value=addon" \
  --set "tolerations[0].effect=NoSchedule" \
  --wait --timeout 10m

echo "=== [5/5] 매니페스트 적용 (Karpenter NodePool/NodeClass -> App -> KEDA) ==="
kubectl apply -f /opt/deploy/karpenter.yaml
kubectl apply -f /opt/deploy/app.yaml
kubectl apply -f /opt/deploy/keda.yaml

echo "=== 완료 ==="
kubectl get pods -n skillsmkt
kubectl get scaledobject -n skillsmkt
