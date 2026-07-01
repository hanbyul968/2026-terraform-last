output "bastion_instance_id" {
  description = "Bastion EC2 인스턴스 ID (SSM 접속 대상)"
  value       = aws_instance.bastion.id
}

output "bastion_public_ip" {
  description = "Bastion EIP (과제 5 SSH 접속 IP)"
  value       = aws_eip.bastion.public_ip
}

output "ssh_connect_command" {
  description = "SSH 접속 명령 (비번: var.ssh_password)"
  value       = "ssh ec2-user@${aws_eip.bastion.public_ip}"
}

output "ssm_connect_command" {
  description = "Windows PowerShell 에서 Bastion 접속 명령"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}"
}

output "bootstrap_bucket" {
  description = "로컬 1과제 코드 번들이 업로드된 부트스트랩 S3 버킷 (destroy 시 함께 삭제)"
  value       = aws_s3_bucket.bootstrap.id
}

output "next_steps" {
  description = "접속 후 Bastion 안에서 실행할 명령"
  value       = <<-EOT

    ── 다음 단계 ────────────────────────────────────────────────
    1) Bastion 접속 (둘 중 하나):
         SSH : ssh ec2-user@${aws_eip.bastion.public_ip}   (비번: Skill53##)
         SSM : aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}

    2) 부트스트랩 완료 대기 (READY 파일 생성될 때까지, 보통 1~2분):
         until [ -f /opt/task1/READY ]; do echo waiting...; sleep 5; done

    3) root 인프라 한 번에 배포 (docker build/push 포함):
         bash /opt/task1/run.sh

    ※ 이 Bastion(wsc-bastion)은 과제 5 채점 대상이자 VPC 소유 스테이지이므로
      채점 전에 destroy 하지 않는다. destroy 순서:
        (a) Bastion 안에서 root destroy: cd /opt/task1/k8s && terraform destroy;
            cd /opt/task1 && terraform destroy
        (b) 그 다음 로컬에서 이 폴더(bastion 스테이지) destroy
    ─────────────────────────────────────────────────────────────
  EOT
}
