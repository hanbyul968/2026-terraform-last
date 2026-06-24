output "bastion_public_ip" {
  description = "Bastion EIP (SSH 접속)"
  value       = aws_eip.bastion.public_ip
}

output "cloudfront_domain" {
  description = "CloudFront 도메인 (채점 진입점)"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "app_lb_dns" {
  description = "Internal App LB DNS"
  value       = aws_lb.app.dns_name
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

output "kms_key_arn" {
  value = aws_kms_key.main.arn
}
