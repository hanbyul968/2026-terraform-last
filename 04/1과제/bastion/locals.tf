# =============================================================================
# 1단계(bastion 스테이지) 로컬값
#   이 스테이지가 이제 "진짜" wsc-vpc / 서브넷 / IGW / NAT / 라우팅을 생성한다.
#   (root 는 이 값들을 data.tf 로 이름/태그 조회한다)
#   ※ 그래딩 태그명/CIDR/AZ 는 root(구 vpc.tf, locals.tf)와 100% 동일하게 유지한다.
# =============================================================================
locals {
  cluster_name = "wsc-eks-cluster"

  # ── VPC / Subnet (Reference01, root locals.tf 와 동일) ─────────────
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
