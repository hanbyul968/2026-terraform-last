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
}
