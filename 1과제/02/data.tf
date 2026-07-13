# ═══════════════════════════════════════════════════════════════
# 네트워크(wskorea26-vpc / 서브넷 / IGW / NAT / 라우팅)는 이제 bastion
# 스테이지(bastion/network.tf)가 생성한다. root(2단계, bastion 안에서 apply)는
# 태그 Name 으로 조회해 참조한다. → bastion 이 클러스터와 같은 VPC 에 있어
# EKS private-only 전환 후에도 kubectl/헬름/포트포워딩이 동작한다.
# ═══════════════════════════════════════════════════════════════

data "aws_vpc" "this" {
  filter {
    name   = "tag:Name"
    values = ["wskorea26-vpc"]
  }
}

data "aws_subnet" "pub_c" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wskorea26-pub-subnet-c"]
  }
}

data "aws_subnet" "pub_d" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wskorea26-pub-subnet-d"]
  }
}

data "aws_subnet" "priv_c" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wskorea26-priv-subnet-c"]
  }
}

data "aws_subnet" "priv_d" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wskorea26-priv-subnet-d"]
  }
}
