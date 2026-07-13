# =============================================================================
# 진짜 VPC(unicorn-vpc)는 1단계(bastion 스테이지, ../bastion 의 module "VPC")가
# 생성한다. root(2단계)는 이름/그룹명으로 data 조회해 참조한다. (remote state 미사용)
#
# 기존 root main.tf 는 module.VPC.* 를 참조했으나, VPC 소유권을 bastion 스테이지로
# 옮기면서 아래 local.* 로 치환했다:
#   module.VPC.vpc_id             -> local.vpc_id
#   module.VPC.public_subnet_ids  -> local.public_subnet_ids
#   module.VPC.private_subnet_ids -> local.private_subnet_ids
#   module.VPC.vpc_endpoint_sg_id -> local.vpc_endpoint_sg_id
# =============================================================================

data "aws_vpc" "unicorn" {
  filter {
    name   = "tag:Name"
    values = ["unicorn-vpc"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.unicorn.id]
  }
  filter {
    name   = "tag:Name"
    values = ["unicorn-subnet-pub-a", "unicorn-subnet-pub-b", "unicorn-subnet-pub-c"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.unicorn.id]
  }
  filter {
    name   = "tag:Name"
    values = ["unicorn-subnet-priv-a", "unicorn-subnet-priv-b", "unicorn-subnet-priv-c"]
  }
}

# VPC Endpoint 용 SG (module VPC 가 "${vpc_name}-vpce-sg" 로 생성)
data "aws_security_group" "vpce" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.unicorn.id]
  }
  filter {
    name   = "group-name"
    values = ["unicorn-vpc-vpce-sg"]
  }
}

locals {
  vpc_id             = data.aws_vpc.unicorn.id
  public_subnet_ids  = data.aws_subnets.public.ids
  private_subnet_ids = data.aws_subnets.private.ids
  vpc_endpoint_sg_id = data.aws_security_group.vpce.id
}
