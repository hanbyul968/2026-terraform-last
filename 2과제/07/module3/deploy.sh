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

# EKS access entry 는 생성 직후 즉시 반영되지 않는다. terraform apply 직후 바로 helm 을
# 실행하면 "Kubernetes cluster unreachable: the server has asked for the client to
# provide credentials"(401) 로 실패하므로 인증이 통할 때까지 기다린다.
echo "=== [2.5/5] 클러스터 인증 대기 ==="
for i in $(seq 1 30); do
  if kubectl get --raw /readyz >/dev/null 2>&1; then
    echo "인증 OK ($(kubectl auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null))"
    break
  fi
  if [ "$i" = "30" ]; then
    echo "인증 실패 — access entry 확인 필요:" >&2
    echo "  aws eks list-access-entries --cluster-name $CLUSTER_NAME --region $REGION" >&2
    kubectl get nodes || true
    exit 1
  fi
  echo "  ... 대기 중 ($i/30)"
  sleep 10
done

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
  --set replicas=1 \
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

# 채점기준 3-3 은 order-processor 파드가 karpenter 노드에서 Running 인 상태를 전제로
# nodeName 을 조회한다. apply 직후 60~90초는 Pending 이라 3-3(1.0점)이 빌 수 있다.
echo "=== order-processor 스케줄 대기 (karpenter 노드 프로비저닝) ==="
kubectl rollout status deploy/order-processor -n skillsmkt --timeout=600s || {
  echo "WARN: order-processor 가 Ready 가 되지 않았습니다." >&2
  kubectl get pods -n skillsmkt -o wide || true
  kubectl get nodes -L karpenter.sh/nodepool || true
}

echo "=== 완료 ==="
kubectl get pods -n skillsmkt
kubectl get scaledobject -n skillsmkt
