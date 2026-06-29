variable "player_id" {
  description = "선수 비번호 (Bastion 리소스 이름/버킷 접두어). 채점 전 destroy하므로 식별용."
  type        = string
  default     = "wsc"
}

variable "region" {
  description = "Bastion 이 생성될 리전 (배포 작업 수행용. module1 과 동일하게 ap-northeast-2)"
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  description = "Bastion EC2 인스턴스 타입 (terraform apply + docker build 수행)"
  type        = string
  default     = "t3.medium"
}

variable "competitor_number" {
  description = "module3(MSK) S3 버킷 이름에 쓰이는 비번호. deploy.sh 가 module3 apply 시 -var 로 전달한다."
  type        = string
  default     = "01"
}
