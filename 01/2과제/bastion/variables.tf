variable "player_id" {
  description = "선수 비번호 (Bastion 리소스 이름 접두어). 채점 전 destroy하므로 식별용."
  type        = string
  default     = "wsc"
}

variable "region" {
  description = "Bastion 이 위치할 AWS 리전 (module-1 과 동일: ap-northeast-2 서울). 4개 모듈은 각자 자체 리전을 사용한다."
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  description = "Bastion EC2 인스턴스 타입 (멀티리전 terraform apply + pymysql layer 빌드 수행)"
  type        = string
  default     = "t3.medium"
}
