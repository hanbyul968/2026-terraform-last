output "bastion_instance_id" {
  description = "Bastion EC2 인스턴스 ID (SSM 접속 대상)"
  value       = aws_instance.bastion.id
}

output "ssm_connect_command" {
  description = "로컬 PowerShell 에서 Bastion 접속 명령"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}"
}

output "bootstrap_bucket" {
  description = "2과제 코드 번들이 업로드된 부트스트랩 S3 버킷 (destroy 시 함께 삭제)"
  value       = aws_s3_bucket.bootstrap.id
}

output "next_steps" {
  description = "SSM 접속 후 Bastion 안에서 실행할 명령"
  value       = <<-EOT

    ── 다음 단계 ────────────────────────────────────────────────
    1) Bastion 접속:
         aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}

    2) 부트스트랩 완료 대기 (READY 파일 생성될 때까지, 보통 2~4분):
         until [ -f /opt/task2/READY ]; do echo waiting...; sleep 5; done

    3) 2과제 4개 모듈 + EKS k8s 단계 순서대로 배포:
         bash /opt/task2/deploy.sh ${var.pin}

    4) 채점 직전(★): 로컬 PowerShell 에서 Bastion 만 제거
         cd bastion; terraform destroy -auto-approve
    ─────────────────────────────────────────────────────────────
  EOT
}
