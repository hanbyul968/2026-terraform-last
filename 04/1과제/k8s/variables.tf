# =============================================================================
# 04 1과제 — 2단계(k8s/helm) 스테이지 변수
#   root(AWS) apply 가 끝난 뒤 실행하며, 모든 AWS 리소스는 이름/태그로 data 조회한다.
#   기본값은 root 의 locals.tf / variables.tf 고정값과 동일하게 맞춰 둔다.
# =============================================================================

variable "region" {
  description = "AWS 리전 (root 과 동일)."
  type        = string
  default     = "ap-northeast-2"
}

variable "cluster_name" {
  description = "EKS 클러스터 이름 (root eks.tf 의 local.cluster_name)."
  type        = string
  default     = "wsc-eks-cluster"
}

variable "table_name" {
  description = "DynamoDB 테이블 이름 (ConfigMap TABLE_NAME)."
  type        = string
  default     = "wsc-table"
}

variable "vpc_name" {
  description = "VPC Name 태그 (LB Controller vpcId data 조회)."
  type        = string
  default     = "wsc-vpc"
}

variable "ecr_repo" {
  description = "book 이미지 ECR 리포 이름."
  type        = string
  default     = "wsc-repo"
}

variable "image_tag" {
  description = "book 이미지 태그 (root ecr.tf 가 push 한 태그)."
  type        = string
  default     = "v1.0.0"
}

variable "tg_name" {
  description = "book Pod TargetGroup 이름 (TargetGroupBinding 대상)."
  type        = string
  default     = "wsc-book-tg"
}

variable "log_group_name" {
  description = "Fluent Bit 가 사용할 CloudWatch Log Group 이름 (root logging.tf)."
  type        = string
  default     = "/wsc/pod/log"
}

variable "log_stream_name" {
  description = "Fluent Bit app 로그 스트림 이름."
  type        = string
  default     = "/wsc/app/log"
}

variable "kms_alias" {
  description = "공용 CMK alias (StorageClass wsc-sc kmsKeyId data 조회)."
  type        = string
  default     = "alias/wsc-key"
}

variable "cluster_dns_domain" {
  description = "클러스터 내부 DNS 도메인 (Grafana datasource URL)."
  type        = string
  default     = "wsc.local"
}

variable "grafana_admin_password" {
  description = "Grafana admin 비밀번호 (과제 고정값 Skill53##)."
  type        = string
  default     = "Skill53##"
}

variable "public_subnet_a_name" {
  description = "Addon LB(ingress) 용 public-a 서브넷 Name 태그."
  type        = string
  default     = "wsc-public-a"
}

variable "public_subnet_c_name" {
  description = "Addon LB(ingress) 용 public-c 서브넷 Name 태그."
  type        = string
  default     = "wsc-public-c"
}
