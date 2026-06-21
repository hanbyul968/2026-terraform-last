$ErrorActionPreference = "Stop"
Write-Host "[deploy] kubeconfig 연결..."
aws eks update-kubeconfig --name $env:CLUSTER_NAME --region $env:REGION

Write-Host "[deploy] KEDA 설치..."
helm repo add kedacore https://kedacore.github.io/charts | Out-Null
helm repo update kedacore | Out-Null
helm upgrade --install keda kedacore/keda -n keda --create-namespace --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$env:KEDA_ROLE_ARN" --set "tolerations[0].key=dedicated" --set "tolerations[0].value=addon" --set "tolerations[0].effect=NoSchedule" --wait --timeout 10m

Write-Host "[deploy] Karpenter 설치..."
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter -n kube-system --set "settings.clusterName=$env:CLUSTER_NAME" --set "settings.clusterEndpoint=$env:CLUSTER_ENDPOINT" --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$env:KARPENTER_ROLE_ARN" --set "tolerations[0].key=dedicated" --set "tolerations[0].value=addon" --set "tolerations[0].effect=NoSchedule" --wait --timeout 10m

Write-Host "[deploy] 매니페스트 적용..."
kubectl apply -f "$env:MANIFEST_DIR/karpenter.yaml"
kubectl apply -f "$env:MANIFEST_DIR/app.yaml"
kubectl apply -f "$env:MANIFEST_DIR/keda.yaml"
Write-Host "[deploy] 완료."