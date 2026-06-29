variable "player_id" {
  description = "선수 비번호 (bastion 리소스 접두어 / 부트스트랩 버킷명)"
  type        = string
  default     = "wsc"
}

variable "region" {
  description = "Bastion 을 띄울 리전 (배포는 각 모듈이 자체 리전 사용). 기본 ap-northeast-2"
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  description = "Bastion 인스턴스 타입"
  type        = string
  default     = "t3.medium"
}
