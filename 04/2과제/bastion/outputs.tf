output "bastion_instance_id" {
  description = "Bastion EC2 인스턴스 ID (SSM 접속 대상)"
  value       = aws_instance.bastion.id
}

output "ssm_connect_command" {
  description = "로컬 PowerShell 에서 Bastion 접속 명령"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}"
}

output "bootstrap_bucket" {
  value = aws_s3_bucket.bootstrap.id
}

output "next_steps" {
  value = <<-EOT

    1) aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}
    2) until [ -f /opt/task2/READY ]; do sleep 5; done
    3) bash /opt/task2/deploy.sh        # module1..4 + k8s(KEDA/Karpenter/Loki/Grafana) 순차 배포
    4) (채점 후) 로컬에서: cd bastion; terraform destroy -auto-approve
  EOT
}
