output "endpoint" {
  description = "Submit this to grader (no path)"
  value       = "http://${aws_cloudfront_distribution.this.domain_name}"
}

output "alb_dns" {
  value = aws_lb.this.dns_name
}

output "ecr_repos" {
  value = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "rds_endpoint" {
  value = aws_db_instance.this.endpoint
}

output "s3_bucket" {
  value = aws_s3_bucket.images.bucket
}

output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "kubeconfig_cmd" {
  value = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${var.region}"
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}
