# ---- Module 1. NoSQL ----
output "m1_table_name" {
  description = "DynamoDB 테이블 이름"
  value       = aws_dynamodb_table.products.name
}

# ---- Module 2. CDN ----
output "m2_bucket" {
  description = "CDN S3 버킷"
  value       = aws_s3_bucket.cdn.id
}

output "m2_cloudfront_domain" {
  description = "CloudFront 도메인 (헤더 검증용). curl -sI https://<domain>/index.html?v=1"
  value       = aws_cloudfront_distribution.cdn.domain_name
}

# ---- Module 3. Workflow ----
output "m3_input_bucket" {
  description = "Workflow 입력 버킷"
  value       = aws_s3_bucket.workflow.id
}

output "m3_state_machine_arn" {
  description = "Step Functions 상태 머신 ARN"
  value       = aws_sfn_state_machine.workflow.arn
}

# ---- Module 4. RDS ----
output "m4_cluster_arn" {
  description = "Aurora 클러스터 ARN"
  value       = aws_rds_cluster.aurora.arn
}

output "m4_secret_arn" {
  description = "Secrets Manager 시크릿 ARN"
  value       = aws_secretsmanager_secret.rds.arn
}

output "m4_lambda_name" {
  description = "RDS 조회 Lambda 이름"
  value       = aws_lambda_function.rds_query.function_name
}
