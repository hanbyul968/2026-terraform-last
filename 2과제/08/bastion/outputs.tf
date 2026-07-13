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

    ── 다음 단계 ────────────────────────────────────────────────
    1) Bastion 접속 (로컬 Windows PowerShell):
         aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}

    2) 부트스트랩 완료 대기 (READY 파일 생성될 때까지, 보통 2~3분):
         until [ -f /opt/task2/READY ]; do echo waiting...; sleep 5; done

    3) (선택) docdb_password 변경이 필요하면 tfvars 수정:
         vi /opt/task2/terraform.tfvars      # docdb_password = "..." (기본: Skills2026!)

    4) 4개 모듈 + in-VPC bastion 한 번에 배포:
         bash /opt/task2/run.sh
       └ 루트 module4 의 in-VPC bastion 이 이어서 CoreDNS 패치 + KEDA/Karpenter +
         worker 이미지 build/push (k8s-apply.sh)를 자동 수행한다.

    5) (검증) 루트 apply 후 in-VPC bastion 진행상황:
         BASTION=$(cd /opt/task2 && terraform output -raw bastion_instance_id)
         aws ssm start-session --target $BASTION --region us-west-2
         # 세션 안에서: sudo tail -f /var/log/skills-bastion-bootstrap.log

    6) 채점 직전(★): 로컬 PowerShell 에서 이 bastion 만 제거 (채점 대상 리소스는 유지)
         cd bastion; terraform destroy -auto-approve
    ─────────────────────────────────────────────────────────────
  EOT
}
