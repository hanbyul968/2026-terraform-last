# ═══════════════════════════════════════════════════════════════
# VPC / Subnet / Route Table  (Reference01)
#
# 채점(1-1) 라우팅 규칙이 매우 엄격하다:
#   - wsc-public-rtb    : igw 경로 1개   (public-a, public-c 연결)
#   - wsc-private-a-rtb : nat 경로 1개
#   - wsc-private-c-rtb : nat 경로 1개
#   - wsc-workload-a-rtb: 경로 0개 (local 만, igw/nat/vpce 금지)
#   - wsc-workload-c-rtb: 경로 0개
# => Gateway Endpoint(S3/DynamoDB)는 private RTB 에만 연결한다.
#    (workload RTB 에 붙이면 vpce 경로가 생겨 채점 0 이 깨짐)
#    workload 서브넷의 노드는 Interface Endpoint 로만 AWS 와 통신.
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

# ═══════════════════════════════════════════════════════════════
# VPC Endpoints
# ═══════════════════════════════════════════════════════════════

# Gateway Endpoint: private RTB 에만 연결 (workload 라우팅 0 유지)
resource "aws_vpc_endpoint" "s3_gw" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_a.id, aws_route_table.private_c.id]
  tags              = { Name = "wsc-s3-gw-endpoint" }
}

resource "aws_vpc_endpoint" "dynamodb_gw" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${local.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_a.id, aws_route_table.private_c.id]
  tags              = { Name = "wsc-dynamodb-gw-endpoint" }
}

# Interface Endpoint 보안그룹: VPC 내부에서 443 허용
resource "aws_security_group" "vpce" {
  name        = "wsc-vpce-sg"
  description = "VPC Interface Endpoint SG"
  vpc_id      = aws_vpc.this.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc-vpce-sg" }
}

locals {
  # workload 노드가 AWS 서비스에 닿기 위한 Interface Endpoint 목록.
  # 인터넷/NAT 가 없으므로 노드가 쓰는 서비스는 전부 여기에 있어야 한다.
  interface_endpoints = [
    "ecr.api", "ecr.dkr", "sts", "logs", "ec2",
    "eks", "eks-auth", "elasticloadbalancing", "autoscaling",
    "ssm", "ssmmessages", "ec2messages", "monitoring",
    "s3", # ECR 레이어(S3) 를 라우팅 없이 받기 위한 Interface 형 S3
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${local.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.workload_a.id, aws_subnet.workload_c.id]
  security_group_ids  = [aws_security_group.vpce.id]
  tags                = { Name = "wsc-${replace(each.key, ".", "-")}-endpoint" }
}
