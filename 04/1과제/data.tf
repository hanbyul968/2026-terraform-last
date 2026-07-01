# ═══════════════════════════════════════════════════════════════
# 진짜 wsc-vpc / 서브넷 / 라우팅은 1단계(bastion 스테이지, bastion/network.tf)가
# 생성한다. root(2단계, bastion 에서 apply)는 이름/태그로 조회해 참조한다.
# (구 vpc.tf 의 aws_vpc.this / aws_subnet.* / aws_route_table.private_* 를 대체)
# ═══════════════════════════════════════════════════════════════

data "aws_vpc" "this" {
  filter {
    name   = "tag:Name"
    values = ["wsc-vpc"]
  }
}

data "aws_subnet" "public_a" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-public-a"]
  }
}

data "aws_subnet" "public_c" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-public-c"]
  }
}

data "aws_subnet" "private_a" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-private-a"]
  }
}

data "aws_subnet" "private_c" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-private-c"]
  }
}

data "aws_subnet" "workload_a" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-workload-a"]
  }
}

data "aws_subnet" "workload_c" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-workload-c"]
  }
}

# Gateway Endpoint(S3/DynamoDB)를 붙일 private 라우팅 테이블 (bastion 스테이지 생성)
data "aws_route_table" "private_a" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-private-a-rtb"]
  }
}

data "aws_route_table" "private_c" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-private-c-rtb"]
  }
}


# ── workload 라우팅 테이블 (평상시 라우팅 0, 채점 1-1-C). bootstrap_egress 로 임시 NAT 경로만 추가 ──
data "aws_route_table" "workload_a" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-workload-a-rtb"]
  }
}

data "aws_route_table" "workload_c" {
  vpc_id = data.aws_vpc.this.id
  filter {
    name   = "tag:Name"
    values = ["wsc-workload-c-rtb"]
  }
}

# 노드 부팅용 임시 egress 에 쓸 NAT (public 서브넷 소재, AZ 별)
data "aws_nat_gateway" "a" {
  subnet_id = data.aws_subnet.public_a.id
  state     = "available"
}

data "aws_nat_gateway" "c" {
  subnet_id = data.aws_subnet.public_c.id
  state     = "available"
}
