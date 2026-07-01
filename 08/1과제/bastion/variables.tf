variable "player_id" {
  description = "선수ID (Bastion 리소스 이름 접두어). 채점 전 destroy하므로 식별용."
  type        = string
}

variable "region" {
  description = "AWS 리전 (문제 요구: ap-northeast-2 서울)"
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  description = "Bastion EC2 인스턴스 타입 (terraform + docker build 용)"
  type        = string
  default     = "t3.medium"
}

# ---- 네트워크(진짜 VPC/서브넷) 파라미터 : 이 스테이지가 VPC 를 생성한다 ----
variable "azs" {
  description = "Public Subnet을 배치할 가용영역 2개 (root 와 동일)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "vpc_cidr" {
  description = "VPC CIDR (문제 고정값, root 와 동일)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public Subnet CIDR 2개 (root 와 동일)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}
