output "cloudfront_domain" {
  description = "CloudFront 도메인 (채점 진입점)"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "s3_bucket" {
  value = aws_s3_bucket.static.bucket
}

output "ecr_repo_url" {
  value = aws_ecr_repository.book.repository_url
}

output "eks_cluster_name" {
  value = aws_eks_cluster.this.name
}

output "lambda_function_url" {
  value = aws_lambda_function_url.book_get.function_url
}

output "alb_dns" {
  value = data.aws_lb.app.dns_name
}

output "bastion_public_ip" {
  description = "Bastion EIP (VPC 내부에서 kubectl/apply 용)"
  value       = aws_eip.bastion.public_ip
}
