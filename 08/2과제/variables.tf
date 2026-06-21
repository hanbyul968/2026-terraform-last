variable "team_id" {
  description = "비번호 (S3 버킷 이름 등에 사용). apply 시 입력. 소문자/숫자/하이픈, 예) 007"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}$", var.team_id))
    error_message = "team_id는 소문자/숫자/하이픈만 사용하고 소문자 또는 숫자로 시작해야 합니다 (S3 버킷명 규칙)."
  }
}

# 계정 ID (ARN 구성에 사용). 리전 무관하므로 기본 provider로 조회.
data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}
