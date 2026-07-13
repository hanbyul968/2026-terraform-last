# ═══════════════════════════════════════════════════════════════
# VPC / Subnet / Route Table  (과제 3, Reference01)
#
# 이 파일은 원래 root(../vpc.tf)에 있던 "진짜 VPC" 정의를 그대로 이관한 것이다.
# 1단계(bastion 스테이지)가 이 VPC/서브넷/IGW/NAT/라우팅을 생성하고,
# 그 안의 hub-sub-a(퍼블릭)에 Bastion 을 띄운다. 덕분에 Bastion 이 클러스터와
# "같은 VPC" 라, EKS private-only 전환 후에도 kubectl/포트포워딩이 계속 동작한다.
# root(2단계)는 data.tf 에서 Name 태그로 이 리소스들을 조회해 참조한다.
#
# 채점(1-1, 1-2):
#   VPC  wsc2026-skills-vpc   192.168.0.0/16
#   hub-sub-a 192.168.1.0/24  -> hub-rtb -> igw   (Public/AZ-a)
#   hub-sub-b 192.168.10.0/24 -> hub-rtb -> igw   (Public/AZ-b)
#   app-sub-a 192.168.2.0/24  -> app-rtb-a -> nat-a (Private/AZ-a)
#   app-sub-b 192.168.20.0/24 -> app-rtb-b -> nat-b (Private/AZ-b)
#   => hub-rtb 는 두 hub 서브넷 공용, app 서브넷은 AZ별 NAT.
# ═══════════════════════════════════════════════════════════════

resource "aws_vpc" "this" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "wsc2026-skills-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "wsc2026-skills-igw" }
}

# ── Public (hub) 서브넷 ───────────────────────────────────────
resource "aws_subnet" "hub_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.subnets.hub_a.cidr
  availability_zone       = local.subnets.hub_a.az
  map_public_ip_on_launch = true
  tags = {
    Name                                          = local.subnets.hub_a.name
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "hub_b" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.subnets.hub_b.cidr
  availability_zone       = local.subnets.hub_b.az
  map_public_ip_on_launch = true
  tags = {
    Name                                          = local.subnets.hub_b.name
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

# ── Private (app) 서브넷 : EKS 노드/Lambda ENI 위치 ───────────
resource "aws_subnet" "app_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.subnets.app_a.cidr
  availability_zone = local.subnets.app_a.az
  tags = {
    Name                                          = local.subnets.app_a.name
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "app_b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.subnets.app_b.cidr
  availability_zone = local.subnets.app_b.az
  tags = {
    Name                                          = local.subnets.app_b.name
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

# ── NAT Gateway (app 서브넷 outbound) ─────────────────────────
resource "aws_eip" "nat_a" {
  domain = "vpc"
  tags   = { Name = "wsc2026-skills-nat-a-eip" }
}

resource "aws_eip" "nat_b" {
  domain = "vpc"
  tags   = { Name = "wsc2026-skills-nat-b-eip" }
}

resource "aws_nat_gateway" "a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.hub_a.id
  tags          = { Name = "wsc2026-skills-nat-a" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "b" {
  allocation_id = aws_eip.nat_b.id
  subnet_id     = aws_subnet.hub_b.id
  tags          = { Name = "wsc2026-skills-nat-b" }
  depends_on    = [aws_internet_gateway.this]
}

# ── Route Tables ──────────────────────────────────────────────
# hub-rtb : 두 hub 서브넷 공용 -> IGW
resource "aws_route_table" "hub" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "wsc2026-skills-hub-rtb" }
}

resource "aws_route_table" "app_a" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.a.id
  }
  tags = { Name = "wsc2026-skills-app-rtb-a" }
}

resource "aws_route_table" "app_b" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.b.id
  }
  tags = { Name = "wsc2026-skills-app-rtb-b" }
}

resource "aws_route_table_association" "hub_a" {
  subnet_id      = aws_subnet.hub_a.id
  route_table_id = aws_route_table.hub.id
}
resource "aws_route_table_association" "hub_b" {
  subnet_id      = aws_subnet.hub_b.id
  route_table_id = aws_route_table.hub.id
}
resource "aws_route_table_association" "app_a" {
  subnet_id      = aws_subnet.app_a.id
  route_table_id = aws_route_table.app_a.id
}
resource "aws_route_table_association" "app_b" {
  subnet_id      = aws_subnet.app_b.id
  route_table_id = aws_route_table.app_b.id
}
