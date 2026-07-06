variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "project" {
  type    = string
  default = "wsi2026"
}

# EKS 클러스터가 아직 없을 때(import/최초 클러스터 생성 단계) false 로 두면
# kubernetes/helm/kubectl provider 가 더미 값을 써서 "Invalid provider configuration"
# 에러 없이 진행됩니다. 클러스터가 생성된 뒤 true 로 바꿔 k8s 리소스를 apply 하세요.
variable "k8s_provider_ready" {
  type    = bool
  default = false
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["ap-northeast-2a", "ap-northeast-2b"]
}

variable "eks_version" {
  type    = string
  default = "1.35"
}

variable "node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "db_name" {
  type    = string
  default = "dev"
}

variable "db_username" {
  type    = string
  default = "appuser"
}

variable "app_image_tag" {
  type        = string
  default     = "latest"
  description = "Tag of the user/product/stress images pushed to ECR"
}

variable "aws_profile" {
  type        = string
  default     = ""
  description = "AWS named profile. Leave empty to use the default credential chain (env vars / default profile)."
}

variable "is_windows" {
  type        = bool
  default     = true
  description = "Set true when running terraform from Windows PowerShell (no bash). build.tf then uses PowerShell instead of /bin/sh for the docker build/push step. CloudShell/Linux?먯꽌 ?ㅽ뻾 ??-var is_windows=false 瑜?吏?뺥븯?몄슂."
}