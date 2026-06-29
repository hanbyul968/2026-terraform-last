variable "bibunho" {
  description = "선수 비번호 (main 스테이지의 S3 버킷 이름에 사용)"
  type        = string
}

variable "instance_type" {
  description = "Bastion 인스턴스 타입 (Docker 빌드를 수행하므로 t3.small 권장)"
  type        = string
  default     = "t3.small"
}

variable "ssh_cidr" {
  description = "Bastion 22번 포트 접속을 허용할 CIDR"
  type        = string
  default     = "0.0.0.0/0"
}

variable "origin_verify_value" {
  description = "main 스테이지로 전달할 CloudFront X-Origin-Verify 헤더 값 (20자 이상)"
  type        = string
  default     = "SkillsKorea2026SecureHeaderValue!!"
}
