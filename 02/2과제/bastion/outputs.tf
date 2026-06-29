output "bastion_instance_id" { value = aws_instance.bastion.id }
output "ssm_connect_command" {
  value = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}"
}
output "bootstrap_bucket" { value = aws_s3_bucket.bootstrap.id }
output "next_steps" {
  value = <<-EOT

    1) aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.region}
    2) until [ -f /opt/task2/READY ]; do sleep 5; done
    3) BIBUNHO=<비번호> bash /opt/task2/deploy.sh
    4) (채점 후) 로컬에서: cd bastion; terraform destroy -auto-approve
  EOT
}
