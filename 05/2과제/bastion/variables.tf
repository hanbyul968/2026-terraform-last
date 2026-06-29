variable "player_id" {
  description = "선수 비번호 (Bastion 리소스 이름 접두어 + 부트스트랩 버킷명). 채점 전 destroy하므로 식별용."
  type        = string
  default     = "wsc"
}

variable "region" {
  description = "Bastion 이 떠 있을 리전 (배포는 Bastion 안에서 멀티리전으로 수행됨). 기본 ap-northeast-2 서울."
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  description = "Bastion EC2 인스턴스 타입 (terraform 멀티리전 apply + Pillow/도커 빌드 수행)"
  type        = string
  default     = "t3.medium"
}

variable "pin" {
  description = "2과제 비번호 - CDN S3 버킷 gj2026-cdn-bucket-<pin> 등에 사용. apply 시 입력받음(필수). 빈 값 입력 시 player_id 사용."
  type        = string
}

variable "alarm_email" {
  description = "Module 3 SNS 이메일 알림 수신 주소 (채점항목 3-8). 미입력 시 구독 생략."
  type        = string
  default     = ""
}
