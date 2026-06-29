# =============================================================================
# 02 1과제 — 2단계(k8s/helm) 스테이지 변수
#   기본값은 root(locals.tf/eks.tf/variables.tf)의 고정값과 동일하게 맞춘다.
#   root apply 가 끝난 뒤 이 값들로 클러스터/ALB/VPC/KMS 를 이름으로 data 조회한다.
# =============================================================================

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

# eks.tf / locals.tf: local.cluster_name = "wskorea26-cluster"
variable "cluster_name" {
  type    = string
  default = "wskorea26-cluster"
}

# vpc.tf: aws_vpc.this tags.Name = "wskorea26-vpc"
variable "vpc_name" {
  type    = string
  default = "wskorea26-vpc"
}

# alb.tf: aws_lb_target_group.book name = "wskorea26-book-tg"
variable "tg_name" {
  type    = string
  default = "wskorea26-book-tg"
}

# locals.tf: local.namespace = "wskorea26"
variable "namespace" {
  type    = string
  default = "wskorea26"
}

# locals.tf: local.table_name = "wskorea26-data-table"
variable "table_name" {
  type    = string
  default = "wskorea26-data-table"
}

# locals.tf: local.ecr_repo = "wskorea26-book-repo"
variable "ecr_repo" {
  type    = string
  default = "wskorea26-book-repo"
}

# locals.tf: local.image_tag = "stable"
variable "image_tag" {
  type    = string
  default = "stable"
}

# logging.tf: aws_cloudwatch_log_group.pod name = "/wskorea26/pod/log"
variable "log_group" {
  type    = string
  default = "/wskorea26/pod/log"
}

# kms.tf: alias/wskorea26-s3-key (EBS 볼륨 암호화에 재사용)
variable "kms_s3_alias" {
  type    = string
  default = "alias/wskorea26-s3-key"
}

# variables.tf(root): grafana admin (채점 10-1: admin / wsk2026!)
variable "grafana_admin_user" {
  type    = string
  default = "admin"
}

variable "grafana_admin_password" {
  type    = string
  default = "wsk2026!"
}
