terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

provider "aws" {
  region = "ap-northeast-3"
}

# ── 변수: 대회 비번호 (S3 버킷 이름에 사용) ──────────────────────────
variable "competitor_number" {
  description = "대회 비번호 (예: 01, 15). S3 버킷 이름 wsc-msk-order-data-<비번호>-bucket 에 사용"
  type        = string
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "wsc-msk-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "wsc-msk-igw" }
}

# Public Subnets (A, C)
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-3a"
  map_public_ip_on_launch = true
  tags = { Name = "wsc-msk-public-a" }
}

resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-northeast-3c"
  map_public_ip_on_launch = true
  tags = { Name = "wsc-msk-public-c" }
}

# Private Subnets (A, C)
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "ap-northeast-3a"
  tags = { Name = "wsc-msk-private-a" }
}

resource "aws_subnet" "private_c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "ap-northeast-3c"
  tags = { Name = "wsc-msk-private-c" }
}

# NAT Gateways (one per AZ)
resource "aws_eip" "nat_a" {
  domain = "vpc"
}

resource "aws_eip" "nat_c" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat_a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.public_a.id
  tags          = { Name = "wsc-msk-nat-a" }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "nat_c" {
  allocation_id = aws_eip.nat_c.id
  subnet_id     = aws_subnet.public_c.id
  tags          = { Name = "wsc-msk-nat-c" }
  depends_on    = [aws_internet_gateway.main]
}

# Route Tables
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "wsc-msk-public-rt" }
}

resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "pub_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_a.id
  }
  tags = { Name = "wsc-msk-private-rt-a" }
}

resource "aws_route_table" "private_c" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_c.id
  }
  tags = { Name = "wsc-msk-private-rt-c" }
}

resource "aws_route_table_association" "priv_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private_a.id
}

resource "aws_route_table_association" "priv_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = aws_route_table.private_c.id
}

# Security Group for MSK
resource "aws_security_group" "msk" {
  name        = "wsc-msk-sg"
  description = "MSK security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
  }

  ingress {
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group for EC2 instances
resource "aws_security_group" "ec2" {
  name        = "wsc-app-ec2-sg"
  description = "App EC2 security group"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 IAM Role (SSM + S3)
resource "aws_iam_role" "ec2" {
  name = "wsc-app-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.ec2.name
}

resource "aws_iam_role_policy" "ec2_s3" {
  name = "wsc-app-ec2-s3-kafka-policy"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
        Resource = ["${aws_s3_bucket.data.arn}", "${aws_s3_bucket.data.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.setup.arn}/*"]
      },
      {
        Effect = "Allow"
        Action = [
          "kafka:ListClusters",
          "kafka:DescribeCluster",
          "kafka:GetBootstrapBrokers",
          "kafka:ListNodes"
        ]
        Resource = "*"
      },
      {
        # 채점/검증 편의: EC2에서 Lambda ESM 상태 확인·enable, DynamoDB 조회
        Effect = "Allow"
        Action = [
          "lambda:ListEventSourceMappings",
          "lambda:GetEventSourceMapping",
          "lambda:UpdateEventSourceMapping",
          "lambda:GetFunction",
          "dynamodb:Scan",
          "dynamodb:DescribeTable",
          "dynamodb:GetItem"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "wsc-app-ec2-profile"
  role = aws_iam_role.ec2.name
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Bastion IAM Role (admin + 신뢰정책 전체 오픈)
resource "aws_iam_role" "bastion" {
  name = "wsc-bastion-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { AWS = "*" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_admin" {
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  role       = aws_iam_role.bastion.name
}

resource "aws_iam_instance_profile" "bastion" {
  name = "wsc-bastion-profile"
  role = aws_iam_role.bastion.name
}

# Bastion EC2 (A존, public subnet)
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public_a.id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true

  tags = { Name = "wsc-bastion-ec2" }
}

# Application EC2 (A존, public subnet)
resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.public_a.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  user_data = <<-EOF
#!/bin/bash
exec > /var/log/user-data.log 2>&1
cd /home/ec2-user

# Java + Python + pip 설치
dnf install -y java-11-amazon-corretto python3 python3-pip

# kafka-python 설치
python3 -m pip install kafka-python-ng boto3

# Kafka 클라이언트 설치 (재시도 3회)
for i in 1 2 3; do
  curl -fO https://archive.apache.org/dist/kafka/3.5.1/kafka_2.13-3.5.1.tgz && break
  echo "Retry $i..." && sleep 10
done
tar -xzf kafka_2.13-3.5.1.tgz
rm -f kafka_2.13-3.5.1.tgz
chown -R ec2-user:ec2-user /home/ec2-user/kafka_2.13-3.5.1

# ec2_consumer.py 다운로드
aws s3 cp s3://wsc-msk-setup-${data.aws_caller_identity.current.account_id}/ec2_consumer.py /home/ec2-user/ec2_consumer.py --region ap-northeast-3
chown ec2-user:ec2-user /home/ec2-user/ec2_consumer.py

# MSK 준비될 때까지 대기 후 consumer 백그라운드 실행
cat > /home/ec2-user/start_consumer.sh << 'SCRIPT'
#!/bin/bash
REGION=ap-northeast-3
BUCKET=wsc-msk-order-data-${data.aws_caller_identity.current.account_id}

# MSK가 ACTIVE 상태가 될 때까지 대기 (최대 30분)
for i in $(seq 1 60); do
  CLUSTER_ARN=$(aws kafka list-clusters --region $REGION \
    --query "ClusterInfoList[?ClusterName=='msk-order-cluster'].ClusterArn" --output text 2>/dev/null)
  STATE=$(aws kafka describe-cluster --cluster-arn $CLUSTER_ARN --region $REGION \
    --query "ClusterInfo.State" --output text 2>/dev/null)
  if [ "$STATE" = "ACTIVE" ]; then
    BOOTSTRAP=$(aws kafka get-bootstrap-brokers --cluster-arn $CLUSTER_ARN \
      --region $REGION --query BootstrapBrokerString --output text)
    break
  fi
  sleep 30
done

# consumer 실행
python3 /home/ec2-user/ec2_consumer.py \
  --bootstrap-servers $BOOTSTRAP \
  --bucket $BUCKET >> /home/ec2-user/consumer.log 2>&1
SCRIPT

# S3 버킷명 실제 값으로 치환
sed -i "s|wsc-msk-order-data-\${data.aws_caller_identity.current.account_id}|wsc-msk-order-data-${data.aws_caller_identity.current.account_id}|g" /home/ec2-user/start_consumer.sh
chmod +x /home/ec2-user/start_consumer.sh
chown ec2-user:ec2-user /home/ec2-user/start_consumer.sh

# 백그라운드 실행
nohup /home/ec2-user/start_consumer.sh &

echo "Setup complete" > /home/ec2-user/setup_done.txt
EOF

  tags = { Name = "wsc-app-ec2" }
}

# S3 Bucket (이름: wsc-msk-order-data-<비번호>-bucket)
resource "aws_s3_bucket" "data" {
  bucket = "wsc-msk-order-data-${var.competitor_number}-bucket"
}

# S3 Bucket for setup files (ec2_consumer.py 등)
resource "aws_s3_bucket" "setup" {
  bucket = "wsc-msk-setup-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_object" "ec2_consumer" {
  bucket = aws_s3_bucket.setup.bucket
  key    = "ec2_consumer.py"
  source = "${path.module}/ec2_consumer.py"
  etag   = filemd5("${path.module}/ec2_consumer.py")
}

# MSK Cluster
resource "aws_msk_cluster" "main" {
  cluster_name           = "msk-order-cluster"
  kafka_version          = "3.6.0"
  number_of_broker_nodes = 2

  broker_node_group_info {
    instance_type   = "kafka.m5.large"
    client_subnets  = [aws_subnet.private_a.id, aws_subnet.private_c.id]
    security_groups = [aws_security_group.msk.id]

    connectivity_info {
      public_access {
        type = "DISABLED"
      }
    }

    storage_info {
      ebs_storage_info {
        volume_size = 100
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "TLS_PLAINTEXT"
      in_cluster    = false
    }
  }
}

# DynamoDB Table
resource "aws_dynamodb_table" "orders" {
  name         = "order-records"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "orderId"
  range_key    = "timestamp"

  attribute {
    name = "orderId"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }
}

# Lambda IAM Role
resource "aws_iam_role" "lambda" {
  name = "msk-order-consumer-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "msk-order-consumer-policy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem"]
        Resource = aws_dynamodb_table.orders.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kafka:DescribeCluster",
          "kafka:GetBootstrapBrokers",
          "kafka:DescribeClusterV2",
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:ReadData",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:AlterGroup"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeVpcs",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

# VPC Lambda는 ENI 생성 권한이 생성 시점에 필요 → 관리형 정책 부착
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  role       = aws_iam_role.lambda.name
}

# IAM 정책 전파 지연(eventual consistency) 대기 → Lambda 생성 시 ENI 권한 확실히 적용
resource "time_sleep" "wait_iam" {
  depends_on = [
    aws_iam_role_policy.lambda,
    aws_iam_role_policy_attachment.lambda_vpc,
  ]
  create_duration = "30s"
}

# Lambda Function
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda.py"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "consumer" {
  function_name    = "msk-order-consumer"
  role             = aws_iam_role.lambda.arn
  handler          = "lambda.handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_c.id]
    security_group_ids = [aws_security_group.msk.id]
  }

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = aws_dynamodb_table.orders.name
      AWS_REGION_NAME     = "ap-northeast-3"
    }
  }

  depends_on = [time_sleep.wait_iam]
}

# MSK Event Source Mapping
resource "aws_lambda_event_source_mapping" "msk" {
  event_source_arn  = aws_msk_cluster.main.arn
  function_name     = aws_lambda_function.consumer.arn
  topics            = ["order-events"]
  starting_position = "TRIM_HORIZON"
  batch_size        = 100
  enabled           = true

  depends_on = [
    aws_msk_cluster.main,
    aws_lambda_function.consumer,
    aws_iam_role_policy.lambda
  ]
}

output "msk_cluster_arn" {
  value = aws_msk_cluster.main.arn
}

output "s3_bucket" {
  value = aws_s3_bucket.data.bucket
}

output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}

output "app_ec2_id" {
  value = aws_instance.app.id
}

output "setup_bucket" {
  value = aws_s3_bucket.setup.bucket
}
