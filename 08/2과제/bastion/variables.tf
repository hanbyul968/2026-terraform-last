variable "player_id" {
  description = "선수 비번호 (Bastion 리소스 이름/버킷 접두어). 채점 전 destroy하므로 식별용."
  type        = string
  default     = "wsc"
}

variable "region" {
  description = "Bastion 이 생성될 리전 (배포 작업 수행용. Module1 과 동일하게 ap-northeast-2)"
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  description = "Bastion EC2 인스턴스 타입 (terraform apply 수행)"
  type        = string
  default     = "t3.small"
}

variable "team_id" {
  description = "비번호 (S3 버킷 이름/Workflow SFN 입력에 사용). deploy.sh 가 루트 apply 및 SFN 실행에 -var 로 전달한다. (기본값 없음 → bastion apply 시 입력)"
  type        = string
}
