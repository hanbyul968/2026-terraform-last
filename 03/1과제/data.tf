# ═══════════════════════════════════════════════════════════════
# VPC / Subnet 조회 (data)
#
# wsc2026-skills-vpc / 서브넷 / IGW / NAT / 라우팅은 1단계(bastion 스테이지,
# ./bastion/network.tf)에서 생성된다. root(2단계, bastion 안에서 apply)는
# 여기서 Name 태그로 조회해 참조한다. (aws_caller_identity/partition/region 은
# providers.tf 에 선언되어 있다.)
# ═══════════════════════════════════════════════════════════════

data "aws_vpc" "this" {
  filter {
    name   = "tag:Name"
    values = ["wsc2026-skills-vpc"]
  }
}

data "aws_subnet" "hub_a" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc2026-skills-hub-sub-a"]
  }
}

data "aws_subnet" "hub_b" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc2026-skills-hub-sub-b"]
  }
}

data "aws_subnet" "app_a" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc2026-skills-app-sub-a"]
  }
}

data "aws_subnet" "app_b" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc2026-skills-app-sub-b"]
  }
}
