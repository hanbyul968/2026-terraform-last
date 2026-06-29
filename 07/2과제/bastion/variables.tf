variable "player_id" {
  description = "선수 비번호 (Bastion/부트스트랩 리소스 이름 접두어). 채점 전 destroy하므로 식별용."
  type        = string
  default     = "wsc"
}

variable "region" {
  description = "Bastion 리전. 07 루트 module4(EKS) 리전과 동일하게 us-west-2 사용."
  type        = string
  default     = "us-west-2"
}

variable "instance_type" {
  description = "Bastion EC2 인스턴스 타입 (terraform apply + docker build/push + helm 수행)."
  type        = string
  default     = "t3.medium"
}
