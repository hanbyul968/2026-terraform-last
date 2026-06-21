output "vpc_id" {
  value = aws_vpc.vpc.id
}

output "subnet_a_id" {
  value = aws_subnet.private_a.id
}

output "subnet_b_id" {
  value = aws_subnet.private_b.id
}

output "eks_cluster_name" {
  value = aws_eks_cluster.cluster.name
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.cluster.endpoint
}

output "eks_node_role_arns" {
  value = { for k, r in aws_iam_role.eks_node : k => r.arn }
}

output "alb_dns" {
  value = aws_lb.alb.dns_name
}

output "alb_arn" {
  value = aws_lb.alb.arn
}

output "book_tg_arn" {
  value = aws_lb_target_group.book.arn
}

output "grafana_tg_arn" {
  value = aws_lb_target_group.grafana.arn
}

output "cloudfront_domain" {
  value = aws_cloudfront_distribution.cdn.domain_name
}

output "lambda_function_url" {
  value = aws_lambda_function_url.reservation.function_url
}

output "ecr_book_uri" {
  value = aws_ecr_repository.book.repository_url
}

output "s3_bucket" {
  value = aws_s3_bucket.static.id
}
