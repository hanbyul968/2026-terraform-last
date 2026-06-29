variable "player_id" {
  description = "선수 비번호 (Bastion 리소스 이름 접두어 + 부트스트랩 버킷 prefix). 채점 전 destroy."
  type        = string
  default     = "wsc"
}

variable "region" {
  description = "Bastion 을 띄울 리전 (module3 와 동일한 ap-northeast-2 권장; 기본 VPC 사용)"
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  description = "Bastion EC2 인스턴스 타입 (terraform 멀티리전 apply + docker build/push 수행)"
  type        = string
  default     = "t3.medium"
}

variable "competitor_number" {
  description = "선수등번호 (deploy.sh -> module4 Grafana 계정/비번 및 setup.sh 에 사용)"
  type        = string
  default     = "00"
}
