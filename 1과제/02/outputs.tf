output "cloudfront_domain" {
  description = "CloudFront 도메인 (채점 진입점)"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "book_alb_dns" {
  description = "book ALB DNS"
  value       = aws_lb.book.dns_name
}

output "s3_bucket" {
  value = aws_s3_bucket.this.bucket
}

output "ecr_repo_url" {
  value = aws_ecr_repository.book.repository_url
}

output "eks_cluster_name" {
  value = aws_eks_cluster.this.name
}

output "grafana_alb_hint" {
  description = "Grafana ALB(wskorea26-grafana-alb) 주소 확인 방법 (채점 10-0과 동일한 명령)"
  value       = "aws elbv2 describe-load-balancers --names wskorea26-grafana-alb --query 'LoadBalancers[0].DNSName' --output text"
}
