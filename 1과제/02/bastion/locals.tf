# ───────────────────────────────────────────────────────────────
# bastion 스테이지가 이제 진짜 과제 VPC(wskorea26-vpc)/서브넷/라우팅을
# 생성한다(network.tf). 아래 local 은 network.tf 의 서브넷 태그
# (kubernetes.io/cluster/<클러스터명>)와 CIDR/AZ 를 root 와 동일하게
# 유지하기 위한 값이다. 값이 바뀌면 root/locals.tf 와 동기화할 것.
# ───────────────────────────────────────────────────────────────
locals {
  # root(../locals.tf).cluster_name 과 반드시 동일해야 서브넷의
  # kubernetes.io/cluster/<name> 디스커버리 태그가 일치한다.
  cluster_name = "wskorea26-cluster"

  # ── VPC / Subnet (Reference01) ─────────────────────────────
  vpc_cidr = "172.16.0.0/16"
  subnets = {
    pub_c  = { cidr = "172.16.1.0/24", az = var.azs[0] }   # wskorea26-pub-subnet-c
    pub_d  = { cidr = "172.16.2.0/24", az = var.azs[1] }   # wskorea26-pub-subnet-d
    priv_c = { cidr = "172.16.201.0/24", az = var.azs[0] } # wskorea26-priv-subnet-c
    priv_d = { cidr = "172.16.202.0/24", az = var.azs[1] } # wskorea26-priv-subnet-d
  }
}
