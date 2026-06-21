output "cloudfront_domain" {
  description = "CloudFront domain (test /index and /main)"
  value       = aws_cloudfront_distribution.static.domain_name
}

output "alb_dns" {
  description = "wsc-alb DNS name (test /health, POST /v1/book)"
  value       = aws_lb.wsc.dns_name
}

output "s3_bucket" {
  value = aws_s3_bucket.static.bucket
}

output "ecr_repo_url" {
  value = aws_ecr_repository.book.repository_url
}

output "eks_cluster" {
  value = aws_eks_cluster.this.name
}

output "kms_key_arn" {
  value = aws_kms_key.main.arn
}
