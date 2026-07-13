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

variable "azs" {
  description = "사용할 가용영역 2개. Reference01 이 c, d 를 사용하므로 순서/문자 중요. root/variables.tf 와 동일하게 유지."
  type        = list(string)
  default     = ["ap-northeast-2c", "ap-northeast-2d"]
}
