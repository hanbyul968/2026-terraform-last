$ErrorActionPreference = "Stop"
Write-Host "[deploy] kubeconfig 연결..."
aws eks update-kubeconfig --name $env:CLUSTER_NAME --region $env:REGION

# EKS access entry 는 생성 직후 즉시 반영되지 않는다. terraform apply 직후 바로 helm 을
# 실행하면 "Kubernetes cluster unreachable: the server has asked for the client to
# provide credentials"(401) 로 실패하므로 인증이 통할 때까지 기다린다.
Write-Host "[deploy] 클러스터 인증 대기..."
$ok = $false
for ($i = 1; $i -le 30; $i++) {
    kubectl get --raw /readyz 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $ok = $true; break }
    Write-Host "  ... 대기 중 ($i/30)"
    Start-Sleep -Seconds 10
}
if (-not $ok) {
    Write-Error "인증 실패 — access entry 확인: aws eks list-access-entries --cluster-name $env:CLUSTER_NAME --region $env:REGION"
}
Write-Host "[deploy] 인증 OK"

Write-Host "[deploy] KEDA 설치..."
helm repo add kedacore https://kedacore.github.io/charts | Out-Null
helm repo update kedacore | Out-Null
helm upgrade --install keda kedacore/keda -n keda --create-namespace --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$env:KEDA_ROLE_ARN" --set "tolerations[0].key=dedicated" --set "tolerations[0].value=addon" --set "tolerations[0].effect=NoSchedule" --wait --timeout 10m

Write-Host "[deploy] Karpenter 설치..."
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter -n kube-system --set replicas=1 --set "settings.clusterName=$env:CLUSTER_NAME" --set "settings.clusterEndpoint=$env:CLUSTER_ENDPOINT" --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$env:KARPENTER_ROLE_ARN" --set "tolerations[0].key=dedicated" --set "tolerations[0].value=addon" --set "tolerations[0].effect=NoSchedule" --wait --timeout 10m

Write-Host "[deploy] 매니페스트 적용..."
kubectl apply -f "$env:MANIFEST_DIR/karpenter.yaml"
kubectl apply -f "$env:MANIFEST_DIR/app.yaml"
kubectl apply -f "$env:MANIFEST_DIR/keda.yaml"
Write-Host "[deploy] 완료."