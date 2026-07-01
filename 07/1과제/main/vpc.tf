# 채점 대상 진짜 VPC(skills-book-vpc)/서브넷/IGW/NAT/RT/VPC엔드포인트는
# bootstrap 스테이지(../bootstrap/network.tf)에서 생성된다. Bastion 이 그 VPC 안에
# 위치하므로, main 은 아래 data 조회로 동일한 네트워크를 참조한다.
data "aws_caller_identity" "current" {}

data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = ["skills-book-vpc"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  filter {
    name   = "tag:Name"
    values = ["skills-book-public-*"]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
  filter {
    name   = "tag:Name"
    values = ["skills-book-private-*"]
  }
}
