locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.region

  # ── 리소스 이름 (과제 고정값) ──────────────────────────────
  cluster_name = "wsc-eks-cluster"
  ecr_repo     = "wsc-repo"
  table_name   = "wsc-table"
  bucket_name  = "wsc-static-${data.aws_caller_identity.current.account_id}"

  registry  = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  image_url = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com/wsc-repo:v1.0.0"

  # ── VPC / Subnet (Reference01) ─────────────────────────────
  vpc_cidr = "10.0.0.0/16"
  subnets = {
    public_a   = { cidr = "10.0.0.0/24", az = var.azs[0] }
    public_c   = { cidr = "10.0.1.0/24", az = var.azs[1] }
    private_a  = { cidr = "10.0.2.0/24", az = var.azs[0] }
    private_c  = { cidr = "10.0.3.0/24", az = var.azs[1] }
    workload_a = { cidr = "10.0.4.0/24", az = var.azs[0] }
    workload_c = { cidr = "10.0.5.0/24", az = var.azs[1] }
  }
}
