output "bastion_instance_id" {
  description = "Bastion EC2 인스턴스 ID (SSM 접속 대상)"
  value       = aws_instance.bastion.id
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
  description = "SSM 접속 후 Bastion 안에서 실행할 명령"
  value       = <<-EOT

    ── 다음 단계 ────────────────────────────────────────────────
    1) Bastion 접속:
         aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}

    2) 부트스트랩 완료 대기 (READY 파일 생성될 때까지, 보통 1~2분):
         until [ -f /opt/task1/READY ]; do echo waiting...; sleep 5; done

    3) main(루트 1과제) 인프라 배포:
         bash /opt/task1/run.sh

    4) (선택) EKS/이미지/모니터링 부트스트랩 — 기존 워크플로우 유지:
         cd /opt/task1 && source manifest/apply.sh
         ※ apply.sh 는 docker/eksctl/helm 이 필요하다. run.sh 의 userdata 는
           terraform 만 설치하므로, apply.sh 사용 시 도구를 추가 설치하거나
           기존대로 CloudShell(unicorn-mark)에서 실행할 것. (manual-review)

    5) 채점 직전(★): 로컬 PowerShell 에서 Bastion 만 제거
         cd bastion; terraform destroy -auto-approve
    ─────────────────────────────────────────────────────────────
  EOT
}
