variable "player_id" {
  description = "선수 비번호 (일부 배포용 리소스 이름 접두어)."
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
  description = "사용할 가용영역 2개. 채점이 a, c 순서를 기대하므로 순서 중요. (root variables.tf 와 동일)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

# ── Bastion SSH 비밀번호 (과제 5 고정값) ──
variable "ssh_password" {
  description = "Bastion SSH 패스워드. 과제: Skill53## (채점은 sshpass 사용)"
  type        = string
  default     = "Skill53##"
}
