variable "player_id" {
  description = "선수 비번호 접두어 (Bastion/부트스트랩 리소스 식별용). 채점 전 destroy 한다."
  type        = string
  default     = "wsc"
}

variable "pin" {
  description = "선수 비번호 (module1 CDN S3 버킷명 wsc2026-cdn-asset-<비번호> 에 사용)"
  type        = string
  default     = "00"
}

variable "region" {
  description = "Bastion 리전 (4개 모듈은 각자 자체 리전을 사용하므로 무관). 기본 서울."
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  description = "Bastion EC2 타입 (멀티리전 terraform apply + Pillow 빌드 + helm/kubectl 수행)"
  type        = string
  default     = "t3.medium"
}
