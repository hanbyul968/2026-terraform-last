terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
    time    = { source = "hashicorp/time", version = "0.13.1" }
  }
}

# 2-4 MSK — ap-northeast-1
provider "aws" {
  region = "ap-northeast-1"
}

data "aws_caller_identity" "current" {}

variable "bibunho" {
  type = string
}

locals {
  producer_app_key     = "artifacts/module4-app"
  producer_support_key = "artifacts/module4-topic-admin.zip"
}

# ── VPC msk-vpc 192.168.0.0/16 ───────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "msk-vpc" }
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "msk-igw" }
}
resource "aws_subnet" "pub_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "192.168.0.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "msk-pub-a" }
}
resource "aws_subnet" "pub_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "192.168.1.0/24"
  availability_zone       = "ap-northeast-1c"
  map_public_ip_on_launch = true
  tags                    = { Name = "msk-pub-b" }
}
resource "aws_subnet" "priv_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.10.0/24"
  availability_zone = "ap-northeast-1a"
  tags              = { Name = "msk-priv-a" }
}
resource "aws_subnet" "priv_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.11.0/24"
  availability_zone = "ap-northeast-1c"
  tags              = { Name = "msk-priv-b" }
}
resource "aws_eip" "nat" { domain = "vpc" }
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.pub_a.id
  tags          = { Name = "msk-ngw" }
  depends_on    = [aws_internet_gateway.main]
}
resource "aws_route_table" "pub" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "msk-pub-rtb" }
}
resource "aws_route_table" "priv_a" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "msk-priv-a-rtb" }
}
resource "aws_route_table" "priv_b" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "msk-priv-b-rtb" }
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

# ── MSK (IAM auth, private, HA) ──────────────────────────────────────
resource "aws_security_group" "msk" {
  name   = "wsc2026-msk-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    description = "kafka IAM TLS"
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = ["192.168.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc2026-msk-sg" }
}
resource "aws_msk_cluster" "main" {
  cluster_name           = "wsc2026-msk-cluster"
  kafka_version          = "3.6.0"
  number_of_broker_nodes = 2
  broker_node_group_info {
    instance_type   = "kafka.t3.small"
    client_subnets  = [aws_subnet.priv_a.id, aws_subnet.priv_b.id]
    security_groups = [aws_security_group.msk.id]
    storage_info {
      ebs_storage_info { volume_size = 20 }
    }
  }
  client_authentication {
    sasl { iam = true }
  }
  encryption_info {
    encryption_in_transit {
      client_broker = "TLS"
      in_cluster    = true
    }
  }
}

# ── Producer EC2 (private, min IAM) ──────────────────────────────────
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
resource "aws_iam_role" "producer" {
  name = "wsc2026-msk-ec2-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "producer_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.producer.name
}
resource "aws_iam_role_policy" "producer_msk" {
  name = "msk-produce"
  role = aws_iam_role.producer.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["kafka-cluster:Connect", "kafka-cluster:WriteData", "kafka-cluster:DescribeTopic", "kafka-cluster:CreateTopic", "kafka-cluster:WriteDataIdempotently", "kafka-cluster:DescribeCluster", "kafka-cluster:AlterCluster", "kafka-cluster:DescribeGroup", "kafka-cluster:AlterGroup"]
        Resource = ["${replace(aws_msk_cluster.main.arn, ":cluster/", ":topic/")}/*", aws_msk_cluster.main.arn, "${replace(aws_msk_cluster.main.arn, ":cluster/", ":group/")}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kafka:DescribeClusterV2", "kafka:GetBootstrapBrokers"]
        Resource = aws_msk_cluster.main.arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.alert.arn}/artifacts/*"
      }
    ]
  })
}
resource "aws_iam_instance_profile" "producer" {
  name = "wsc2026-msk-ec2-profile"
  role = aws_iam_role.producer.name
}
resource "aws_security_group" "producer" {
  name   = "wsc2026-sensor-producer-sg"
  vpc_id = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc2026-sensor-producer-sg" }
}
resource "aws_instance" "producer" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.priv_a.id
  vpc_security_group_ids      = [aws_security_group.producer.id]
  iam_instance_profile        = aws_iam_instance_profile.producer.name
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    region      = "ap-northeast-1"
    msk_arn     = aws_msk_cluster.main.arn
    app_bucket  = aws_s3_bucket.alert.id
    app_key     = local.producer_app_key
    support_key = local.producer_support_key
  })
  tags = { Name = "wsc2026-sensor-producer" }
  depends_on = [
    aws_iam_role_policy.producer_msk,
    aws_s3_object.producer_app,
    aws_s3_object.producer_support
  ]
}

# ── Storage: DynamoDB, S3, SNS ───────────────────────────────────────
resource "aws_dynamodb_table" "sensor" {
  name         = "wsc2026-sensor-data"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "sensorId"
  range_key    = "timestamp"
  attribute {
    name = "sensorId"
    type = "S"
  }
  attribute {
    name = "timestamp"
    type = "S"
  }
}
resource "aws_s3_bucket" "alert" {
  bucket        = "wsc2026-sensor-alert-bucket-${var.bibunho}"
  force_destroy = true
}
resource "aws_s3_object" "producer_app" {
  bucket = aws_s3_bucket.alert.id
  key    = local.producer_app_key
  source = "${path.module}/app/app"
  etag   = filemd5("${path.module}/app/app")
}
resource "aws_s3_object" "producer_support" {
  bucket      = aws_s3_bucket.alert.id
  key         = local.producer_support_key
  source      = data.archive_file.raw_lambda.output_path
  source_hash = data.archive_file.raw_lambda.output_base64sha256
}
resource "aws_sns_topic" "alert" {
  name = "wsc2026-sensor-alert"
}

# ── Consumer Lambdas (MSK trigger, min IAM) ──────────────────────────
resource "aws_iam_role" "lambda" {
  name = "wsc2026-msk-lambda-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  role       = aws_iam_role.lambda.name
}
resource "aws_iam_role_policy" "lambda" {
  name = "consume-min"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DiscoverMSKCluster"
        Effect = "Allow"
        Action = [
          "kafka:DescribeClusterV2",
          "kafka:GetBootstrapBrokers"
        ]
        Resource = aws_msk_cluster.main.arn
      },
      {
        Sid    = "ConsumeFromMSKWithIAM"
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:AlterGroup",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:ReadData",
          "kafka-cluster:WriteData",
          "kafka-cluster:WriteDataIdempotently"
        ]
        Resource = [
          aws_msk_cluster.main.arn,
          "${replace(aws_msk_cluster.main.arn, ":cluster/", ":topic/")}/wsc2026-sensor-raw",
          "${replace(aws_msk_cluster.main.arn, ":cluster/", ":topic/")}/wsc2026-sensor-alert",
          "${replace(aws_msk_cluster.main.arn, ":cluster/", ":group/")}/wsc2026-sensor-raw-cg",
          "${replace(aws_msk_cluster.main.arn, ":cluster/", ":group/")}/wsc2026-sensor-alert-cg"
        ]
      },
      {
        Sid      = "DiscoverMSKVpc"
        Effect   = "Allow"
        Action   = ["ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups"]
        Resource = "*"
      },
      {
        Sid      = "WriteSensorData"
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.sensor.arn
      },
      {
        Sid      = "WriteAlertObject"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.alert.arn}/*"
      },
      {
        Sid      = "PublishAlert"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alert.arn
      }
    ]
  })
}

# Event Source Mapping 생성 API가 갱신된 IAM 정책을 보기 전에 실행되는 것을 방지한다.
resource "time_sleep" "lambda_iam_propagation" {
  create_duration = "20s"
  triggers = {
    role_name   = aws_iam_role.lambda.name
    policy_hash = sha256(aws_iam_role_policy.lambda.policy)
  }
  depends_on = [
    aws_iam_role_policy.lambda,
    aws_iam_role_policy_attachment.lambda_vpc
  ]
}
data "archive_file" "raw_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/raw"
  output_path = "${path.module}/raw-consumer.zip"
}
data "archive_file" "alert_lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/alert"
  output_path = "${path.module}/alert-consumer.zip"
}
resource "aws_security_group" "lambda" {
  name   = "wsc2026-msk-lambda-sg"
  vpc_id = aws_vpc.main.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc2026-msk-lambda-sg" }
}
resource "aws_lambda_function" "raw" {
  function_name    = "wsc2026-sensor-consumer"
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  runtime          = "python3.14"
  filename         = data.archive_file.raw_lambda.output_path
  source_code_hash = data.archive_file.raw_lambda.output_base64sha256
  timeout          = 120
  vpc_config {
    subnet_ids         = [aws_subnet.priv_a.id, aws_subnet.priv_b.id]
    security_group_ids = [aws_security_group.lambda.id]
  }
  environment {
    variables = {
      DDB_TABLE        = aws_dynamodb_table.sensor.name
      ALERT_TOPIC      = "wsc2026-sensor-alert"
      BOOTSTRAP_SERVER = aws_msk_cluster.main.bootstrap_brokers_sasl_iam
    }
  }
}
resource "aws_lambda_function" "alert" {
  function_name    = "wsc2026-sensor-alert-consumer"
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  runtime          = "python3.14"
  filename         = data.archive_file.alert_lambda.output_path
  source_code_hash = data.archive_file.alert_lambda.output_base64sha256
  timeout          = 60
  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.alert.arn
      S3_BUCKET     = aws_s3_bucket.alert.id
    }
  }
}
resource "aws_lambda_event_source_mapping" "raw" {
  event_source_arn  = aws_msk_cluster.main.arn
  function_name     = aws_lambda_function.raw.arn
  topics            = ["wsc2026-sensor-raw"]
  starting_position = "TRIM_HORIZON"
  depends_on        = [time_sleep.lambda_iam_propagation]
  amazon_managed_kafka_event_source_config {
    consumer_group_id = "wsc2026-sensor-raw-cg"
  }
}
resource "aws_lambda_event_source_mapping" "alert" {
  event_source_arn  = aws_msk_cluster.main.arn
  function_name     = aws_lambda_function.alert.arn
  topics            = ["wsc2026-sensor-alert"]
  starting_position = "TRIM_HORIZON"
  depends_on        = [time_sleep.lambda_iam_propagation]
  amazon_managed_kafka_event_source_config {
    consumer_group_id = "wsc2026-sensor-alert-cg"
  }
}

output "msk_arn" { value = aws_msk_cluster.main.arn }
output "sensor_table" { value = aws_dynamodb_table.sensor.name }
output "alert_bucket" { value = aws_s3_bucket.alert.id }
