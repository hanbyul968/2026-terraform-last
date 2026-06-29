output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "region" {
  value = data.aws_region.current.name
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}
