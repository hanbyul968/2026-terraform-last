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
  description = "Bastion EC2 인스턴스 타입 (terraform + docker build 수행)"
  type        = string
  default     = "t3.medium"
}

# 루트(main) 1과제가 요구하는 no-default 변수. Bastion 안에서 main apply 시
# /opt/task1/terraform.tfvars 로 기록되어 자동 주입된다. 대회 당일 본인 비번호로 변경.
variable "bi_number" {
  description = "비번호 (루트 1과제 var.bi_number 로 전달; gj2026-static-<비번호> 버킷 등에 사용). 고정 default 없음 → 로컬 bastion apply 시 입력."
  type        = string
}
