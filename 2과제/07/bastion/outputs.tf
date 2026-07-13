output "bastion_instance_id" {
  description = "Bastion EC2 인스턴스 ID (SSM 접속 대상)"
  value       = aws_instance.bastion.id
}

output "ssm_connect_command" {
  description = "Windows PowerShell 에서 Bastion 접속 명령"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}"
}

output "bootstrap_bucket" {
  description = "로컬 2과제 코드 번들이 업로드된 부트스트랩 S3 버킷 (destroy 시 함께 삭제)"
  value       = aws_s3_bucket.bootstrap.id
}

output "next_steps" {
  description = "SSM 접속 후 Bastion 안에서 실행할 명령"
  value       = <<-EOT

    ── 2단계 배포 절차 ──────────────────────────────────────────
    [1단계] (로컬 Windows PowerShell) Bastion 생성 — 지금 막 완료됨.

    [2단계] Bastion 접속 후 전체 모듈 배포:
      1) 접속:
           aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}

      2) 부트스트랩 완료 대기 (READY 파일, 보통 2~3분):
           until [ -f /opt/task2/READY ]; do echo waiting...; sleep 5; done

      3) 4개 모듈 + k8s 워크로드 한 번에 배포:
           sudo bash /opt/task2/deploy.sh ${var.competitor_number}
         (선수등번호를 인자로 전달. module4 Grafana 계정/비번에 사용됨)

      4) 채점 직전(★): 로컬 PowerShell 에서 Bastion 만 제거
           cd bastion; terraform destroy -auto-approve
    ─────────────────────────────────────────────────────────────
  EOT
}
