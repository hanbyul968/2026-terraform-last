provider "aws" {
  region = "ap-northeast-2"
}

############################
# VPC
############################

resource "aws_vpc" "vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "gj2026-vpc" }
}

############################
# Internet Gateway
############################

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags   = { Name = "gj2026-igw" }
}

############################
# Private Subnets
############################

resource "aws_subnet" "private_a" {
  vpc_id                                      = aws_vpc.vpc.id
  cidr_block                                  = "10.0.10.0/24"
  availability_zone                           = "ap-northeast-2a"
  enable_resource_name_dns_a_record_on_launch = true
  tags = {
    Name                                       = "gj2026-private-subnet-a"
    "kubernetes.io/cluster/gj2026-eks-cluster" = "shared"
    "kubernetes.io/role/internal-elb"          = "1"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id                                      = aws_vpc.vpc.id
  cidr_block                                  = "10.0.11.0/24"
  availability_zone                           = "ap-northeast-2b"
  enable_resource_name_dns_a_record_on_launch = true
  tags = {
    Name                                       = "gj2026-private-subnet-b"
    "kubernetes.io/cluster/gj2026-eks-cluster" = "shared"
    "kubernetes.io/role/internal-elb"          = "1"
  }
}

############################
# Route Tables
############################

resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.vpc.id
  tags   = { Name = "gj2026-private-rtb-a" }
}

resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.vpc.id
  tags   = { Name = "gj2026-private-rtb-b" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private_b.id
}

############################
# Security Groups
############################

resource "aws_security_group" "vpce" {
  name        = "gj2026-vpce-sg"
  description = "VPC Endpoint Security Group"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "alb" {
  name        = "gj2026-alb-sg"
  description = "ALB Security Group"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "eks_cluster" {
  name        = "gj2026-eks-cluster-sg"
  description = "EKS Cluster Security Group"
  vpc_id      = aws_vpc.vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################
# Gateway Endpoints
############################

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.vpc.id
  service_name      = "com.amazonaws.ap-northeast-2.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_a.id, aws_route_table.private_b.id]
  tags              = { Name = "gj2026-s3-endpoint" }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.vpc.id
  service_name      = "com.amazonaws.ap-northeast-2.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_a.id, aws_route_table.private_b.id]
  tags              = { Name = "gj2026-dynamodb-endpoint" }
}

############################
# Interface Endpoints
############################

locals {
  interface_endpoints = [
    "ecr.api", "ecr.dkr", "sts", "logs", "ec2",
    "eks", "eks-auth", "elasticloadbalancing",
    "autoscaling", "ssm", "ssmmessages", "ec2messages", "monitoring"
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = aws_vpc.vpc.id
  service_name        = "com.amazonaws.ap-northeast-2.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  security_group_ids  = [aws_security_group.vpce.id]
  tags                = { Name = "gj2026-${replace(each.key, ".", "-")}-endpoint" }
}
