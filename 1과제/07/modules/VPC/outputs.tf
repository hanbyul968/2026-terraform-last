output "vpc_id" {
  description = "The ID of the VPC"
  value       = aws_vpc.unicorn.id
}

output "vpc_cidr" {
  description = "The CIDR block of the VPC"
  value       = aws_vpc.unicorn.cidr_block
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "vpc_endpoint_sg_id" {
  description = "Security group ID for VPC endpoints"
  value       = aws_security_group.vpc_endpoint.id
}
