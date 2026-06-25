variable "pin" {
  description = "비번호 (경기번호) - S3 버킷 이름에 사용: gj2026-cdn-bucket-<pin>"
  type        = string
}

variable "cdn_public_url" {
  description = <<-EOT
    Lambda Function URL 접근 방식.
    true  = 공개(NONE) — 대회 기본값(공개 URL 허용 계정)
    false = AWS_IAM + CloudFront OAC — 공개 Function URL이 차단된 계정용(이 연습 계정)
  EOT
  type        = bool
  default     = true
}
