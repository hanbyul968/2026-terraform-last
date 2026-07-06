locals {
  name = var.project
  tags = {
    Project = var.project
  }
  account_id   = data.aws_caller_identity.current.account_id
  oidc_arn     = aws_iam_openid_connect_provider.eks.arn
  oidc_url     = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
  profile_args = var.aws_profile != "" ? ["--profile", var.aws_profile] : []
  exec_env     = var.aws_profile != "" ? { AWS_PROFILE = var.aws_profile } : {}

  # 클러스터 이름은 항상 정적으로 알 수 있으므로 provider exec 에 그대로 사용.
  eks_cluster_name = "${local.name}-cluster"
  # k8s_provider_ready=false 면 아직 생성 전이므로 더미 값을 사용(연결은 실제 apply 시에만 발생).
  eks_host = var.k8s_provider_ready ? aws_eks_cluster.this.endpoint : "https://localhost"
  eks_ca   = var.k8s_provider_ready ? base64decode(aws_eks_cluster.this.certificate_authority[0].data) : ""
}
