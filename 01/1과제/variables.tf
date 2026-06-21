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
