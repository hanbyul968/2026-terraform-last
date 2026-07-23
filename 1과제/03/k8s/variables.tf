# =============================================================================
# 03 1과제 — 2단계(k8s/helm) 스테이지 변수
#   기본값은 root(locals.tf)의 고정 이름과 동일하게 맞춰 둠.
# =============================================================================

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

# root locals.cluster_name 과 동일
variable "cluster_name" {
  type    = string
  default = "wsc2026-eks-cluster"
}

variable "cluster_dns_domain" {
  description = "Kubernetes 내부 DNS 도메인. root cluster_dns_domain과 동일해야 함."
  type        = string
  default     = "wsc2026.skills.local"
}


variable "table_name" {
  type    = string
  default = "wsc2026-book-table"
}

# root aws_vpc.this 의 Name 태그
variable "vpc_name" {
  type    = string
  default = "wsc2026-skills-vpc"
}

variable "ecr_repo" {
  type    = string
  default = "wsc2026-book-ecr"
}

variable "image_tag" {
  type    = string
  default = "v1.0.0"
}

# ── Namespace / 앱 이름 (root locals 과 동일) ──
variable "app_namespace" {
  type    = string
  default = "wsc2026"
}

variable "obs_namespace" {
  type    = string
  default = "observability"
}

variable "deploy_name" {
  type    = string
  default = "wsc2026-book-deploy"
}

variable "service_name" {
  type    = string
  default = "wsc2026-book-svc"
}

variable "ingress_name" {
  type    = string
  default = "wsc2026-book-ingress"
}

variable "pdb_name" {
  type    = string
  default = "wsc2026-book-pdb"
}

variable "sa_name" {
  type    = string
  default = "wsc2026-book-sa"
}

variable "dashboard_name" {
  type    = string
  default = "wsc2026-grafana-dashboard"
}

# ── ALB (root 의 LBC ingress 가 만든 ALB / SG) 조회용 ──
variable "alb_name" {
  type    = string
  default = "wsc2026-app-alb"
}

variable "alb_sg_name" {
  type    = string
  default = "wsc2026-app-alb-sg"
}

# root aws_subnet.hub_* 의 Name 태그 (ingress 의 public subnet 지정)
variable "hub_subnet_a_name" {
  type    = string
  default = "wsc2026-skills-hub-sub-a"
}

variable "hub_subnet_b_name" {
  type    = string
  default = "wsc2026-skills-hub-sub-b"
}

# ── 관측 ──
variable "grafana_admin_password" {
  type    = string
  default = "Skills$#$@!"
}

# root aws_cloudwatch_log_group.app 의 이름
variable "app_log_group" {
  type    = string
  default = "/wsc2026/app/log"
}
