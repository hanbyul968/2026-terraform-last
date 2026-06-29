output "vpc_id" { value = module.VPC.vpc_id }
output "bastion_public_ip" { value = aws_eip.bastion.public_ip }
output "code_bucket" { value = aws_s3_bucket.code.id }

output "ssh_command" {
  value = "ssh ec2-user@${aws_eip.bastion.public_ip}  (password: worldpay2026!)"
}
