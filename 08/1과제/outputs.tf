output "cloudfront_domain_name" {
  description = "사용자 접근용 CloudFront 도메인 (정적 웹 + API). https://<도메인>/"
  value       = aws_cloudfront_distribution.cdn.domain_name
}

output "cloudfront_url" {
  description = "CloudFront 접근 URL"
  value       = "https://${aws_cloudfront_distribution.cdn.domain_name}/"
}

output "alb_dns_name" {
  description = "ALB DNS (채점 4-5 /health 확인용. 사용자는 직접 호출 금지)"
  value       = aws_lb.book.dns_name
}

output "ecr_repository_url" {
  description = "ECR Repository URL"
  value       = aws_ecr_repository.book.repository_url
}

output "dynamodb_table_name" {
  description = "DynamoDB 테이블 이름"
  value       = aws_dynamodb_table.booking.name
}

output "s3_bucket_name" {
  description = "정적 웹 호스팅 S3 버킷 이름"
  value       = aws_s3_bucket.static.id
}

output "ecs_cluster_name" {
  description = "ECS 클러스터 이름"
  value       = aws_ecs_cluster.book.name
}

output "vpc_id" {
  description = "생성된 VPC ID"
  value       = aws_vpc.main.id
}
