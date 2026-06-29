output "bastion_public_ip" {
  description = "Bastion public IP"
  value       = aws_instance.bastion.public_ip
}

output "ssh_command" {
  description = "Bastion 접속 명령 (bootstrap 디렉터리에서 실행)"
  value       = "ssh -i bastion-key.pem ec2-user@${aws_instance.bastion.public_ip}"
}

output "next_steps" {
  description = "다음 단계"
  value       = <<-EOT
    1) ssh -i bastion-key.pem ec2-user@${aws_instance.bastion.public_ip}
    2) ./apply.sh        # Bastion 안에서 채점 대상 인프라(main) 생성
    3) (선택) main 생성 완료 후 로컬에서 `terraform destroy` 로 Bastion 정리
  EOT
}
