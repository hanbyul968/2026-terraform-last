# 이 스테이지(로컬 1단계)가 이제 wsc2026-skills-vpc + 서브넷 + IGW/NAT/라우팅 까지 생성한다.
# (bastion 이 같은 VPC 의 hub-sub-a 에 위치해, EKS private-only 전환 후에도 클러스터 접근 가능)
# 아래 값들은 root/locals.tf 의 네트워크 관련 값과 반드시 동일해야 한다.
# root 는 이 이름 태그(Name)로 data.tf 에서 조회하기 때문이다.
locals {
  # EKS 서브넷 kubernetes.io/cluster 태그에 사용 (root/locals.tf 와 동일)
  cluster_name = "wsc2026-eks-cluster"

  # ── VPC / Subnet (Reference01, root/locals.tf 와 동일) ──────
  vpc_cidr = "192.168.0.0/16"

  # hub = Public (IGW), app = Private (NAT)
  subnets = {
    hub_a = { name = "wsc2026-skills-hub-sub-a", cidr = "192.168.1.0/24", az = var.azs[0], public = true }
    hub_b = { name = "wsc2026-skills-hub-sub-b", cidr = "192.168.10.0/24", az = var.azs[1], public = true }
    app_a = { name = "wsc2026-skills-app-sub-a", cidr = "192.168.2.0/24", az = var.azs[0], public = false }
    app_b = { name = "wsc2026-skills-app-sub-b", cidr = "192.168.20.0/24", az = var.azs[1], public = false }
  }
}
