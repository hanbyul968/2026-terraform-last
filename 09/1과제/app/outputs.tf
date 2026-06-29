output "ecr_repository_url" { value = module.ECR.repository_url }
output "cloudfront_domain" { value = module.CloudFront.domain_name }
output "book_alb_dns" { value = aws_lb.book.dns_name }
output "grafana_alb_dns" { value = aws_lb.grafana.dns_name }
output "manifest_bucket" { value = aws_s3_bucket.manifest.id }
output "s3_hosting_bucket" { value = module.S3.bucket_id }
