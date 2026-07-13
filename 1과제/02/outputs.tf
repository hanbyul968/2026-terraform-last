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

output "grafana_lb_hint" {
  description = "Grafana LB 주소는 다음으로 확인: kubectl get svc grafana -n monitoring"
  value       = "kubectl get svc grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}
