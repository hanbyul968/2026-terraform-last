#!/bin/bash
# =============================================================================
# deploy_k8s.sh  (bash 변환본 — 원본: deploy_k8s.ps1, 동작 동일)
#   module3 EKS Scaling 의 k8s 단계: kubeconfig 연결 -> KEDA -> Karpenter ->
#   매니페스트(karpenter/app/keda) 적용. Linux Bastion 에서 실행된다.
#
#   필요 환경변수 (상위 deploy.sh 가 module3 S3 번들의 env.sh + MANIFEST_DIR 로 주입):
#     CLUSTER_NAME       EKS 클러스터 이름 (skm-eks-cluster)
#     REGION             리전 (ap-northeast-2)
#     CLUSTER_ENDPOINT   EKS API 엔드포인트
#     KEDA_ROLE_ARN      KEDA IRSA 역할 ARN
#     KARPENTER_ROLE_ARN Karpenter IRSA 역할 ARN
#     MANIFEST_DIR       렌더링된 karpenter.yaml/app.yaml/keda.yaml 디렉터리
# =============================================================================
set -euo pipefail

echo "[deploy] kubeconfig 연결..."
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

echo "[deploy] KEDA 설치..."
helm repo add kedacore https://kedacore.github.io/charts >/dev/null
helm repo update kedacore >/dev/null
helm upgrade --install keda kedacore/keda -n keda --create-namespace \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KEDA_ROLE_ARN}" \
  --set "tolerations[0].key=dedicated" \
  --set "tolerations[0].value=addon" \
  --set "tolerations[0].effect=NoSchedule" \
  --wait --timeout 10m

echo "[deploy] Karpenter 설치..."
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter -n kube-system \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_ROLE_ARN}" \
  --set "tolerations[0].key=dedicated" \
  --set "tolerations[0].value=addon" \
  --set "tolerations[0].effect=NoSchedule" \
  --wait --timeout 10m

echo "[deploy] 매니페스트 적용..."
kubectl apply -f "${MANIFEST_DIR}/karpenter.yaml"
kubectl apply -f "${MANIFEST_DIR}/app.yaml"
kubectl apply -f "${MANIFEST_DIR}/keda.yaml"
echo "[deploy] 완료."
