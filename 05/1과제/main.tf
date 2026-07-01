provider "aws" {
  region = "ap-northeast-2"
}

# 네트워킹(VPC/서브넷/SG/엔드포인트)은 bastion/(1단계, Windows)에서 생성.
# root(2단계, bastion 내부 apply)는 data source 로 조회한다.
data "aws_vpc" "vpc" {
  filter {
    name   = "tag:Name"
    values = ["gj2026-vpc"]
  }
}

data "aws_subnet" "private_a" {
  filter {
    name   = "tag:Name"
    values = ["gj2026-private-subnet-a"]
  }
}

data "aws_subnet" "private_b" {
  filter {
    name   = "tag:Name"
    values = ["gj2026-private-subnet-b"]
  }
}

data "aws_security_group" "alb" {
  vpc_id = data.aws_vpc.vpc.id
  filter {
    name   = "group-name"
    values = ["gj2026-alb-sg"]
  }
}

data "aws_security_group" "eks_cluster" {
  vpc_id = data.aws_vpc.vpc.id
  filter {
    name   = "group-name"
    values = ["gj2026-eks-cluster-sg"]
  }
}
