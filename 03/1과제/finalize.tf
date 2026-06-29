############################
# 모든 k8s/helm/앱 적용이 끝난 뒤 EKS public endpoint 비활성화 -> private only
#   - 채점 4-1 요구사항: endpointPublicAccess=False, endpointPrivateAccess=True
#   - main 은 Linux Bastion 에서 apply 되므로 bash 로 작성한다.
#   - update-cluster-config 는 비동기이므로, 실제 False 로 반영될 때까지 폴링한다.
#   NOTE: 이후 terraform destroy / 재apply 전에는 아래로 잠시 public 을 켜야 한다.
#     aws eks update-cluster-config --name wsc2026-eks-cluster \
#       --resources-vpc-config endpointPublicAccess=true,endpointPrivateAccess=true
############################
resource "null_resource" "private_only" {
  triggers = {
    cluster = aws_eks_cluster.this.name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION  = local.region
      CLUSTER = aws_eks_cluster.this.name
    }
    command = <<-EOT
      set -euo pipefail
      # 현재 public 이면 끈다 (idempotent)
      CUR=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
        --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text)
      if [ "$CUR" = "True" ] || [ "$CUR" = "true" ]; then
        aws eks update-cluster-config --region "$REGION" --name "$CLUSTER" \
          --resources-vpc-config endpointPublicAccess=false,endpointPrivateAccess=true,publicAccessCidrs=[]
      fi
      # 실제 False 로 반영될 때까지 대기 (최대 ~10분)
      for i in $(seq 1 60); do
        ST=$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
          --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text)
        if [ "$ST" = "False" ] || [ "$ST" = "false" ]; then
          echo "EKS public endpoint disabled (private-only)."
          exit 0
        fi
        sleep 10
      done
      echo "WARN: public endpoint still enabled after wait" >&2
      exit 1
    EOT
  }

  # 폴더의 TERMINAL 리소스들 (k8s/helm/앱 적용이 전부 끝난 뒤 endpoint 를 닫는다)
  depends_on = [
    kubernetes_deployment_v1.book,
    kubernetes_service_v1.book,
    kubernetes_ingress_v1.book,
    kubernetes_pod_disruption_budget_v1.book,
    helm_release.lb_controller,
    helm_release.kps,
    helm_release.fluentbit,
    null_resource.wait_alb,
  ]
}
