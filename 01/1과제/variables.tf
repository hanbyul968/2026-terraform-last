variable "region" {
  description = "AWS region (must be ap-northeast-2 per problem statement)"
  type        = string
  default     = "ap-northeast-2"
}

variable "competitor_number" {
  description = "비번호 - used for the S3 bucket suffix wsc-2026-bucket-<비번호>. Grading only checks the 'wsc-2026-bucket-' prefix."
  type        = string
  default     = "101"
}

variable "azs" {
  description = "Availability zones for subnets a/b"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2b"]
}

variable "grader_principal_arn" {
  description = "채점(CloudShell 등) IAM principal ARN(역할 ARN). 설정 시 EKS ClusterAdmin access entry 생성. 비워두면 생성 안 함(클러스터 생성자=bastion 은 bootstrap 으로 이미 admin)."
  type        = string
  default     = ""
}
