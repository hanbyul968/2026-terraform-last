locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.region

  # CMK 관리 주체 (variables.tf 설명 참고)
  #   bastion 에서 apply 하면 caller 가 일회성 STS 세션 ARN(assumed-role/ROLE/SESSION)이라
  #   그대로 키 정책 Principal 로 쓰면 세션 종료 후 키가 영구 잠긴다.
  #   => 세션 ARN 이면 지속되는 '역할 ARN'(arn:...:role/ROLE) 으로 정규화한다. (root/kms:* 미사용 유지)
  kms_admin_arn = (
    var.kms_admin_arn != "" ? var.kms_admin_arn :
    can(regex("^arn:[^:]+:sts::[0-9]+:assumed-role/", data.aws_caller_identity.current.arn)) ?
    format("arn:%s:iam::%s:role/%s", data.aws_partition.current.partition, data.aws_caller_identity.current.account_id, split("/", data.aws_caller_identity.current.arn)[1]) :
    data.aws_caller_identity.current.arn
  )

  # ── 리소스 이름 (과제 고정값) ───────────────────────────────
  cluster_name = "wsc2026-eks-cluster"
  ecr_repo     = "wsc2026-book-ecr"
  table_name   = "wsc2026-book-table"
  bucket_name  = "wsc2026-static-${var.bucket_rand}-${var.bi_number}-bucket"

  registry  = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  image_tag = "v1.0.0"
  image_url = "${local.registry}/${local.ecr_repo}:${local.image_tag}"

  # ── VPC / Subnet (Reference01) ──────────────────────────────
  vpc_cidr = "192.168.0.0/16"

  # hub = Public (IGW), app = Private (NAT)
  subnets = {
    hub_a = { name = "wsc2026-skills-hub-sub-a", cidr = "192.168.1.0/24", az = var.azs[0], public = true }
    hub_b = { name = "wsc2026-skills-hub-sub-b", cidr = "192.168.10.0/24", az = var.azs[1], public = true }
    app_a = { name = "wsc2026-skills-app-sub-a", cidr = "192.168.2.0/24", az = var.azs[0], public = false }
    app_b = { name = "wsc2026-skills-app-sub-b", cidr = "192.168.20.0/24", az = var.azs[1], public = false }
  }

  # ── CMK alias 이름 (과제 고정값, 채점 check_kms 가 alias 로 조회) ──
  kms_db       = "wsc2026-db-kms"
  kms_ecr      = "wsc2026-ecr-kms"
  kms_eks      = "wsc2026-eks-kms"
  kms_bucket   = "wsc2026-bucket-kms"
  kms_function = "wsc2026-function-kms"

  # ── Deployment / 앱 이름 (과제 8) ───────────────────────────
  app_namespace  = "wsc2026"
  deploy_name    = "wsc2026-book-deploy"
  service_name   = "wsc2026-book-svc"
  ingress_name   = "wsc2026-book-ingress"
  pdb_name       = "wsc2026-book-pdb"
  sa_name        = "wsc2026-book-sa"
  pod_role_name  = "wsc2026-book-pod-role"
  func_role_name = "wsc2026-book-function-role"
  func_policy    = "wsc2026-book-function-policy"
  lambda_name    = "wsc2026-book-get-function"
  alb_name       = "wsc2026-app-alb"
  alb_sg_name    = "wsc2026-app-alb-sg"
  obs_namespace  = "observability"
  dashboard_name = "wsc2026-grafana-dashboard"
  cdn_name       = "wsc2026-cdn"
  waf_name       = "wsc2026-waf"
}
