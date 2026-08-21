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

# root run.sh에서 입력받은 선수 비번호. Grafana 관리자 ID에 사용한다.
variable "bi_number" {
  description = "선수 비번호. Grafana 관리자 ID skills-<비번호>-admin 생성에 사용."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.bi_number))
    error_message = "bi_number는 숫자로만 입력해야 합니다."
  }
}

# Grafana 관리자 (vf 채점 10-1: skills-<비번호>-admin / \$korea26!!)
variable "grafana_admin_password" {
  description = "Grafana 관리자 비밀번호. 백슬래시 1개가 실제 문자로 포함된다."
  type        = string
  default     = "\\$korea26!!"
  sensitive   = true
}

# Grafana ALB(Ingress) 가 배치될 퍼블릭 서브넷 이름 (Reference01)
variable "pub_subnet_names" {
  description = "Grafana ALB 를 배치할 퍼블릭 서브넷 Name 태그 목록."
  type        = list(string)
  default     = ["wskorea26-pub-subnet-c", "wskorea26-pub-subnet-d"]
}
