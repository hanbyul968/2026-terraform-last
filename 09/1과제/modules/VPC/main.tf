resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = var.vpc_name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.vpc_name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnets_cidr)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnets_cidr[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = var.public_subnet_names[count.index] }
}

resource "aws_subnet" "isolated" {
  count             = length(var.isolated_subnets_cidr)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.isolated_subnets_cidr[count.index]
  availability_zone = var.availability_zones[count.index]
  tags              = { Name = var.isolated_subnet_names[count.index] }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.vpc_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "isolated" {
  count  = length(var.isolated_subnets_cidr)
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.vpc_name}-isolated-rt-${count.index}" }
}

resource "aws_route_table_association" "isolated" {
  count          = length(aws_subnet.isolated)
  subnet_id      = aws_subnet.isolated[count.index].id
  route_table_id = aws_route_table.isolated[count.index].id
}

# VPC Endpoints for EKS Private Cluster
resource "aws_security_group" "vpce" {
  name   = "${var.vpc_name}-vpce-sg"
  vpc_id = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.vpc_name}-vpce-sg" }
}

locals {
  interface_endpoints = [
    "com.amazonaws.ap-northeast-2.eks",
    "com.amazonaws.ap-northeast-2.eks-auth",
    "com.amazonaws.ap-northeast-2.ecr.api",
    "com.amazonaws.ap-northeast-2.ecr.dkr",
    "com.amazonaws.ap-northeast-2.sts",
    "com.amazonaws.ap-northeast-2.logs",
    "com.amazonaws.ap-northeast-2.ec2",
    "com.amazonaws.ap-northeast-2.elasticloadbalancing",
    "com.amazonaws.ap-northeast-2.kms",
  ]
}

resource "aws_vpc_endpoint" "interface" {
  count               = length(local.interface_endpoints)
  vpc_id              = aws_vpc.this.id
  service_name        = local.interface_endpoints[count.index]
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.isolated[*].id
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true
  tags                = { Name = "${var.vpc_name}-vpce-${split(".", local.interface_endpoints[count.index])[3]}" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.ap-northeast-2.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.isolated[*].id
  tags              = { Name = "${var.vpc_name}-vpce-s3" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.ap-northeast-2.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.isolated[*].id
  tags              = { Name = "${var.vpc_name}-vpce-dynamodb" }
}
