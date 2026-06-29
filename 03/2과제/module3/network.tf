# =============================================================================
# 03/2과제 Module 3. Container Logging  | Region: ap-northeast-1 (도쿄)
#   EKS + Fluent Bit + OTel Collector + Loki + Prometheus + Grafana 로깅 파이프라인
#   TF: VPC + EKS + 관리형 노드그룹 (PUBLIC endpoint)
#   k8s/Helm 배포는 bastion 의 deploy_k8s.sh 에서 수행 (NEEDS-REVIEW: 런타임)
#   ※ 자체 state.
# =============================================================================
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.60" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  cluster_name = "wsc2026-logging-cluster"
  az_a         = "ap-northeast-1a"
  az_c         = "ap-northeast-1c"
}

# ─────────────────────────────────────────────
# VPC : wsc2026-logging-vpc 10.30.0.0/16
# ─────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.30.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "wsc2026-logging-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "wsc2026-logging-igw" }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.30.1.0/24"
  availability_zone       = local.az_a
  map_public_ip_on_launch = true
  tags = {
    Name                                            = "wsc2026-public-subnet-a"
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/wsc2026-logging-cluster" = "shared"
  }
}

resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.30.2.0/24"
  availability_zone       = local.az_c
  map_public_ip_on_launch = true
  tags = {
    Name                                            = "wsc2026-public-subnet-c"
    "kubernetes.io/role/elb"                        = "1"
    "kubernetes.io/cluster/wsc2026-logging-cluster" = "shared"
  }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.30.10.0/24"
  availability_zone = local.az_a
  tags = {
    Name                                            = "wsc2026-private-subnet-a"
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/wsc2026-logging-cluster" = "shared"
  }
}

resource "aws_subnet" "private_c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.30.20.0/24"
  availability_zone = local.az_c
  tags = {
    Name                                            = "wsc2026-private-subnet-c"
    "kubernetes.io/role/internal-elb"               = "1"
    "kubernetes.io/cluster/wsc2026-logging-cluster" = "shared"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "wsc2026-logging-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
  tags          = { Name = "wsc2026-logging-nat" }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "wsc2026-logging-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "wsc2026-logging-private-rt" }
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
  route_table_id = aws_route_table.private.id
}
resource "aws_route_table_association" "private_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = aws_route_table.private.id
}
