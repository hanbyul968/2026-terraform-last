# ═══════════════════════════════════════════════════════════════
# VPC / Subnet / Route Table  (Reference01, 과제 3)
#
# 이 bastion 스테이지가 진짜 과제 VPC(wskorea26-vpc)와 서브넷/IGW/NAT/라우팅을
# 생성한다. bastion EC2 는 이 VPC 의 퍼블릭 서브넷(wskorea26-pub-subnet-c)에
# 위치하므로, EKS private-only 노드/클러스터와 같은 VPC 안에서 kubectl/헬름/
# 포트포워딩이 계속 동작한다. root(2단계)는 data.tf 로 이 리소스들을 조회한다.
#
# 채점(1-1) CIDR:
#   VPC                      172.16.0.0/16
#   wskorea26-pub-subnet-c   172.16.1.0/24
#   wskorea26-pub-subnet-d   172.16.2.0/24
#   wskorea26-priv-subnet-c  172.16.201.0/24
#   wskorea26-priv-subnet-d  172.16.202.0/24
# 채점(1-2) 라우팅:
#   wskorea26-public-rtb     -> 0.0.0.0/0 = IGW(book-igw)
#   wskorea26-private-rtb-c  -> 0.0.0.0/0 = NAT(book-ngw-c)
#   wskorea26-private-rtb-d  -> 0.0.0.0/0 = NAT(book-ngw-d)
# Private 서브넷은 NAT 로 인터넷 egress 가 있으므로 노드가 ECR/헬름차트
# 이미지를 그대로 pull 할 수 있다. (VPC Endpoint 불필요)
# ═══════════════════════════════════════════════════════════════

resource "aws_vpc" "this" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "wskorea26-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "book-igw" }
}

# ── Public Subnets ────────────────────────────────────────────
resource "aws_subnet" "pub_c" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.subnets.pub_c.cidr
  availability_zone       = local.subnets.pub_c.az
  map_public_ip_on_launch = true
  tags = {
    Name                                          = "wskorea26-pub-subnet-c"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "pub_d" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.subnets.pub_d.cidr
  availability_zone       = local.subnets.pub_d.az
  map_public_ip_on_launch = true
  tags = {
    Name                                          = "wskorea26-pub-subnet-d"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

# ── Private Subnets (EKS Cluster/Nodes) ───────────────────────
resource "aws_subnet" "priv_c" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.subnets.priv_c.cidr
  availability_zone = local.subnets.priv_c.az
  tags = {
    Name                                          = "wskorea26-priv-subnet-c"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "priv_d" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.subnets.priv_d.cidr
  availability_zone = local.subnets.priv_d.az
  tags = {
    Name                                          = "wskorea26-priv-subnet-d"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

# ── NAT (private 서브넷 outbound) ─────────────────────────────
resource "aws_eip" "nat_c" {
  domain = "vpc"
  tags   = { Name = "book-ngw-c-eip" }
}

resource "aws_eip" "nat_d" {
  domain = "vpc"
  tags   = { Name = "book-ngw-d-eip" }
}

resource "aws_nat_gateway" "c" {
  allocation_id = aws_eip.nat_c.id
  subnet_id     = aws_subnet.pub_c.id
  tags          = { Name = "book-ngw-c" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "d" {
  allocation_id = aws_eip.nat_d.id
  subnet_id     = aws_subnet.pub_d.id
  tags          = { Name = "book-ngw-d" }
  depends_on    = [aws_internet_gateway.this]
}

# ── Route Tables ──────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "wskorea26-public-rtb" }
}

resource "aws_route_table" "private_c" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.c.id
  }
  tags = { Name = "wskorea26-private-rtb-c" }
}

resource "aws_route_table" "private_d" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.d.id
  }
  tags = { Name = "wskorea26-private-rtb-d" }
}

resource "aws_route_table_association" "pub_c" {
  subnet_id      = aws_subnet.pub_c.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "pub_d" {
  subnet_id      = aws_subnet.pub_d.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "priv_c" {
  subnet_id      = aws_subnet.priv_c.id
  route_table_id = aws_route_table.private_c.id
}
resource "aws_route_table_association" "priv_d" {
  subnet_id      = aws_subnet.priv_d.id
  route_table_id = aws_route_table.private_d.id
}
