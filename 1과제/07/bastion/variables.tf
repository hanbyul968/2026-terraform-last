variable "player_id" {
  description = "선수 비번호 (Bastion 리소스 이름 접두어). 채점 전 destroy하므로 식별용."
  type        = string
  default     = "wsc"
}

variable "region" {
  description = "AWS 리전 (문제 요구: ap-northeast-2 서울)"
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  description = "Bastion EC2 인스턴스 타입 (terraform apply 수행)"
  type        = string
  default     = "t3.medium"
}

# 루트(main) 의 no-default 변수. 로컬 PowerShell 1단계에서 입력받아 Bastion 의
# /opt/task1/terraform.tfvars 로 전달된다. (루트 main.tf: variable "number")
variable "number" {
  description = "선수 비번호 (루트 main 의 var.number 로 전달, 예: 103)"
  type        = string
}
