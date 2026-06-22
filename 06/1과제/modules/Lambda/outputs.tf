output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "invoke_arn" {
  value = aws_lambda_function.this.invoke_arn
}

output "lambda_sg_id" {
  description = "Security group ID for Lambda"
  value       = aws_security_group.lambda.id
}
