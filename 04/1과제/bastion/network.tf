# ═══════════════════════════════════════════════════════════════
# VPC / Subnet / Route Table  (1단계 = bastion 스테이지가 소유)
#
# 구 root/vpc.tf 의 네트워크(진짜 wsc-vpc)를 이 스테이지로 이동했다.
# → bastion 이 "진짜 VPC 의 진짜 퍼블릭 서브넷"(wsc-public-a)에 위치하므로
#   EKS private-only 전환 후에도 클러스터/포트포워딩이 계속 동작한다.
# → root(2단계)는 aws_vpc.this / aws_subnet.* 를 data.tf 로 조회해 참조한다.
#
# 채점(1-1) 라우팅 규칙(엄격) — root 때와 동일하게 유지:
#   - wsc-public-rtb    : igw 경로 1개   (public-a, public-c 연결)
#   - wsc-private-a-rtb : nat 경로 1개
#   - wsc-private-c-rtb : nat 경로 1개
#   - wsc-workload-a-rtb: 경로 0개 (local 만)
#   - wsc-workload-c-rtb: 경로 0개
# (Gateway Endpoint(S3/DynamoDB)는 root/vpc.tf 가 private RTB 에만 data 로 연결)
# ═══════════════════════════════════════════════════════════════

resource "aws_vpc" "this" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "wsc-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "wsc-igw" }
}

# ── Subnets ───────────────────────────────────────────────────
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.subnets.public_a.cidr
  availability_zone       = local.subnets.public_a.az
  map_public_ip_on_launch = true
  tags = {
    Name                                          = "wsc-public-a"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.subnets.public_c.cidr
  availability_zone       = local.subnets.public_c.az
  map_public_ip_on_launch = true
  tags = {
    Name                                          = "wsc-public-c"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.subnets.private_a.cidr
  availability_zone = local.subnets.private_a.az
  tags = {
    Name                              = "wsc-private-a"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_subnet" "private_c" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.subnets.private_c.cidr
  availability_zone = local.subnets.private_c.az
  tags = {
    Name                              = "wsc-private-c"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# workload = EKS 노드/컨트롤플레인 ENI. 인터넷/NAT 없음.
resource "aws_subnet" "workload_a" {
  vpc_id                                      = aws_vpc.this.id
  cidr_block                                  = local.subnets.workload_a.cidr
  availability_zone                           = local.subnets.workload_a.az
  enable_resource_name_dns_a_record_on_launch = true
  private_dns_hostname_type_on_launch         = "resource-name"
  tags = {
    Name                                          = "wsc-workload-a"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "workload_c" {
  vpc_id                                      = aws_vpc.this.id
  cidr_block                                  = local.subnets.workload_c.cidr
  availability_zone                           = local.subnets.workload_c.az
  enable_resource_name_dns_a_record_on_launch = true
  private_dns_hostname_type_on_launch         = "resource-name"
  tags = {
    Name                                          = "wsc-workload-c"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

# ── NAT (private 서브넷 outbound) ─────────────────────────────
resource "aws_eip" "nat_a" {
  domain = "vpc"
  tags   = { Name = "wsc-nat-a-eip" }
}

resource "aws_eip" "nat_c" {
  domain = "vpc"
  tags   = { Name = "wsc-nat-c-eip" }
}

resource "aws_nat_gateway" "a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.public_a.id
  tags          = { Name = "wsc-nat-a" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "c" {
  allocation_id = aws_eip.nat_c.id
  subnet_id     = aws_subnet.public_c.id
  tags          = { Name = "wsc-nat-c" }
  depends_on    = [aws_internet_gateway.this]
}

# ── Route Tables ──────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "wsc-public-rtb" }
}

resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.a.id
  }
  tags = { Name = "wsc-private-a-rtb" }
}

resource "aws_route_table" "private_c" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.c.id
  }
  tags = { Name = "wsc-private-c-rtb" }
}

# workload RTB: local 외 경로 없음 (채점 0)
resource "aws_route_table" "workload_a" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "wsc-workload-a-rtb" }
}

resource "aws_route_table" "workload_c" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "wsc-workload-c-rtb" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}
resource "aws_route_table_association" "private_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = aws_route_table.private_c.id
}
resource "aws_route_table_association" "workload_a" {
  subnet_id      = aws_subnet.workload_a.id
  route_table_id = aws_route_table.workload_a.id
}
resource "aws_route_table_association" "workload_c" {
  subnet_id      = aws_subnet.workload_c.id
  route_table_id = aws_route_table.workload_c.id
}
