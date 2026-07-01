output "cloudfront_domain" {
  description = "CloudFront 도메인 (채점 진입점)"
  value       = try(aws_cloudfront_distribution.this[0].domain_name, "")
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
  value = try(data.aws_lb.app[0].dns_name, "")
}

# (제거됨) bastion_public_ip — VPC 내부 배포용 bastion 은 외부 bastion/ 스테이지로
# 대체되어 bastion.tf 가 bastion.tf.OLD-in-main 으로 비활성화되었다.

