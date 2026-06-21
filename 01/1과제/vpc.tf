############################
# VPC
############################
resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "wsc-vpc" }
}

############################
# Subnets
############################
resource "aws_subnet" "pub_a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = var.azs[0]
  map_public_ip_on_launch = true
  tags = {
    Name                                          = "wsc-pub-sn-a"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "pub_b" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = var.azs[1]
  map_public_ip_on_launch = true
  tags = {
    Name                                          = "wsc-pub-sn-b"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "priv_a" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = var.azs[0]
  tags = {
    Name                                          = "wsc-priv-sn-a"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "priv_b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = var.azs[1]
  tags = {
    Name                                          = "wsc-priv-sn-b"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

############################
# Internet Gateway
############################
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "wsc-igw" }
}

############################
# NAT Gateways (one per AZ, HA)
############################
resource "aws_eip" "nat_a" {
  domain = "vpc"
  tags   = { Name = "wsc-nat-a-eip" }
}

resource "aws_eip" "nat_b" {
  domain = "vpc"
  tags   = { Name = "wsc-nat-b-eip" }
}

resource "aws_nat_gateway" "a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.pub_a.id
  tags          = { Name = "wsc-nat-a" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "b" {
  allocation_id = aws_eip.nat_b.id
  subnet_id     = aws_subnet.pub_b.id
  tags          = { Name = "wsc-nat-b" }
  depends_on    = [aws_internet_gateway.this]
}

############################
# Route Tables
############################
resource "aws_route_table" "pub" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "wsc-pub-rt" }
}

resource "aws_route_table" "priv_a" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.a.id
  }
  tags = { Name = "wsc-priv-rt-a" }
}

resource "aws_route_table" "priv_b" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.b.id
  }
  tags = { Name = "wsc-priv-rt-b" }
}

resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.pub_a.id
  route_table_id = aws_route_table.pub.id
}

resource "aws_route_table_association" "pub_b" {
  subnet_id      = aws_subnet.pub_b.id
  route_table_id = aws_route_table.pub.id
}

resource "aws_route_table_association" "priv_a" {
  subnet_id      = aws_subnet.priv_a.id
  route_table_id = aws_route_table.priv_a.id
}

resource "aws_route_table_association" "priv_b" {
  subnet_id      = aws_subnet.priv_b.id
  route_table_id = aws_route_table.priv_b.id
}

############################
# VPC Flow Logs -> CloudWatch Logs (KMS encrypted, custom format)
############################
resource "aws_cloudwatch_log_group" "flowlogs" {
  name              = "/aws/vpc/flowlogs"
  retention_in_days = 7
  kms_key_id        = aws_kms_key.main.arn
  tags              = { Name = "/aws/vpc/flowlogs" }
}

resource "aws_iam_role" "flowlogs" {
  name = "wsc-vpc-flowlogs-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flowlogs" {
  name = "wsc-vpc-flowlogs-policy"
  role = aws_iam_role.flowlogs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "${aws_cloudwatch_log_group.flowlogs.arn}:*"
    }]
  })
}

# 로그 필드: account-id vpc-id subnet-id region srcaddr dstaddr srcport dstport
#            action protocol start end  (12개만)
# terraform 가 ${...} 를 보간하지 않도록 $$ 로 이스케이프.
resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flowlogs.arn
  iam_role_arn             = aws_iam_role.flowlogs.arn
  max_aggregation_interval = 60

  log_format = "$${account-id} $${srcaddr} $${dstaddr} $${srcport} $${dstport} $${protocol} $${start} $${end} $${action} $${vpc-id} $${subnet-id} $${region}"

  tags = { Name = "wsc-vpc-flowlog" }
}
