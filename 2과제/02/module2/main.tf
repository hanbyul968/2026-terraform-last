terraform {
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 6.0" }
    null = { source = "hashicorp/null", version = "~> 3.0" }
  }
}

# 2-2 Real-time data analytics — ap-northeast-2
provider "aws" {
  region = "ap-northeast-2"
}

# ── VPC analytics-vpc 10.20.0.0/16 ───────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "analytics-vpc" }
}
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "analytics-igw" }
}
resource "aws_subnet" "pub_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.0.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true
  tags                    = { Name = "analytics-pub-a" }
}
resource "aws_subnet" "pub_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = true
  tags                    = { Name = "analytics-pub-b" }
}
resource "aws_subnet" "priv_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.100.0/24"
  availability_zone = "ap-northeast-2a"
  tags              = { Name = "analytics-priv-a" }
}
resource "aws_subnet" "priv_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.20.101.0/24"
  availability_zone = "ap-northeast-2c"
  tags              = { Name = "analytics-priv-b" }
}
resource "aws_eip" "nat" { domain = "vpc" }
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.pub_a.id
  tags          = { Name = "analytics-ngw" }
  depends_on    = [aws_internet_gateway.main]
}
resource "aws_route_table" "pub" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "analytics-pub-rtb" }
}
resource "aws_route_table" "priv_a" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "analytics-priv-a-rtb" }
}
resource "aws_route_table" "priv_b" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "analytics-priv-b-rtb" }
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

# ── Kinesis Data Stream (on-demand) ──────────────────────────────────
resource "aws_kinesis_stream" "orders" {
  name = "wsc2026-order-stream"
  stream_mode_details { stream_mode = "ON_DEMAND" }
}

# ── EC2 (private, SSM) producing order logs to Kinesis ───────────────
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
resource "aws_iam_role" "ec2" {
  name = "wsc2026-alaytics-ec2-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.ec2.name
}
resource "aws_iam_role_policy" "ec2_kinesis" {
  name = "kinesis-put"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["kinesis:PutRecord", "kinesis:PutRecords", "kinesis:DescribeStream"], Resource = aws_kinesis_stream.orders.arn }]
  })
}
resource "aws_iam_instance_profile" "ec2" {
  name = "wsc2026-analytics-ec2-profile"
  role = aws_iam_role.ec2.name
}
resource "aws_security_group" "ec2" {
  name   = "wsc2026-analytics-ec2-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    description     = "from ALB 5000"
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc2026-analytics-ec2-sg" }
}
resource "aws_instance" "ec2" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.small"
  subnet_id                   = aws_subnet.priv_a.id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    app_py       = file("${path.module}/app/app.py")
    requirements = file("${path.module}/app/requirements.txt")
    region       = "ap-northeast-2"
    stream       = aws_kinesis_stream.orders.name
  })
  tags = { Name = "wsc2026-analytics-ec2" }
}

# ── ALB ──────────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name   = "wsc2026-analytics-alb-sg"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc2026-analytics-alb-sg" }
}
resource "aws_lb" "main" {
  name               = "wsc2026-analytics-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.pub_a.id, aws_subnet.pub_b.id]
  tags               = { Name = "wsc2026-analytics-alb" }
}
resource "aws_lb_target_group" "main" {
  name        = "wsc2026-analytics-tg"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"
  health_check {
    path    = "/health"
    matcher = "200"
  }
}
resource "aws_lb_target_group_attachment" "main" {
  target_group_arn = aws_lb_target_group.main.arn
  target_id        = aws_instance.ec2.id
  port             = 5000
}
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# ── Managed Apache Flink Studio (Zeppelin) ───────────────────────────
data "aws_caller_identity" "current" {}

# Studio Notebook의 SQL Catalog로 사용할 Glue 데이터베이스.
# CreateApplication은 CatalogConfiguration이 없으면 이름이 default인 DB를 조회한다.
resource "aws_glue_catalog_database" "flink" {
  name        = "default"
  description = "Glue Data Catalog for wsc2026-analytics-flink Studio Notebook"
}

locals {
  flink_glue_catalog_arn  = "arn:aws:glue:ap-northeast-2:${data.aws_caller_identity.current.account_id}:catalog"
  flink_glue_database_arn = "arn:aws:glue:ap-northeast-2:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.flink.name}"

  flink_application_configuration = jsonencode({
    FlinkApplicationConfiguration = {
      ParallelismConfiguration = {
        ConfigurationType = "CUSTOM"
        Parallelism       = 1
        ParallelismPerKPU = 1
      }
    }
    ZeppelinApplicationConfiguration = {
      MonitoringConfiguration = {
        LogLevel = "INFO"
      }
      CatalogConfiguration = {
        GlueDataCatalogConfiguration = {
          DatabaseARN = local.flink_glue_database_arn
        }
      }
    }
  })
}

resource "aws_iam_role" "flink" {
  name = "wsc2026-analytics-flink-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "kinesisanalytics.amazonaws.com" } }]
  })
}

# AWS 공식 Studio Notebook 정책 예시에 따라 Kinesis source와 Glue Catalog에
# 필요한 작업만 허용한다.
resource "aws_iam_role_policy" "flink" {
  name = "flink-min"
  role = aws_iam_role.flink.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "KinesisShardDiscovery"
        Effect   = "Allow"
        Action   = "kinesis:ListShards"
        Resource = "*"
      },
      {
        Sid    = "KinesisShardConsumption"
        Effect = "Allow"
        Action = [
          "kinesis:GetShardIterator",
          "kinesis:GetRecords",
          "kinesis:DescribeStream",
          "kinesis:DescribeStreamSummary",
          "kinesis:RegisterStreamConsumer",
          "kinesis:DeregisterStreamConsumer"
        ]
        Resource = aws_kinesis_stream.orders.arn
      },
      {
        Sid      = "KinesisEfoConsumer"
        Effect   = "Allow"
        Action   = ["kinesis:DescribeStreamConsumer", "kinesis:SubscribeToShard"]
        Resource = "${aws_kinesis_stream.orders.arn}/consumer/*"
      },
      {
        Sid    = "GlueTable"
        Effect = "Allow"
        Action = [
          "glue:GetConnection",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetDatabase",
          "glue:CreateTable",
          "glue:UpdateTable"
        ]
        Resource = [
          "arn:aws:glue:ap-northeast-2:${data.aws_caller_identity.current.account_id}:connection/*",
          "arn:aws:glue:ap-northeast-2:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.flink.name}/*",
          local.flink_glue_database_arn,
          "arn:aws:glue:ap-northeast-2:${data.aws_caller_identity.current.account_id}:database/hive",
          local.flink_glue_catalog_arn
        ]
      },
      {
        Sid      = "GlueDatabaseList"
        Effect   = "Allow"
        Action   = "glue:GetDatabases"
        Resource = "*"
      },
      {
        Sid      = "CloudWatchMetrics"
        Effect   = "Allow"
        Action   = "cloudwatch:PutMetricData"
        Resource = "*"
      },
      {
        Sid      = "CloudWatchLogGroupList"
        Effect   = "Allow"
        Action   = "logs:DescribeLogGroups"
        Resource = "arn:aws:logs:ap-northeast-2:${data.aws_caller_identity.current.account_id}:log-group:*"
      }
    ]
  })
}

resource "null_resource" "flink" {
  triggers = {
    name               = "wsc2026-analytics-flink"
    role               = aws_iam_role.flink.arn
    database_arn       = local.flink_glue_database_arn
    policy_hash        = sha256(aws_iam_role_policy.flink.policy)
    configuration_hash = sha256(local.flink_application_configuration)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION     = "ap-northeast-2"
      ROLE       = aws_iam_role.flink.arn
      APP_CONFIG = local.flink_application_configuration
    }
    command = <<-EOT
      set -eu
      APP_NAME="wsc2026-analytics-flink"

      if aws kinesisanalyticsv2 describe-application --region "$REGION" --application-name "$APP_NAME" >/dev/null 2>&1; then
        echo "flink studio exists"
        exit 0
      fi

      # IAM 정책과 새 Glue DB가 각 서비스에 전파될 때까지 검증 오류만 재시도한다.
      for attempt in $(seq 1 12); do
        set +e
        output=$(aws kinesisanalyticsv2 create-application --region "$REGION" \
          --application-name "$APP_NAME" \
          --runtime-environment ZEPPELIN-FLINK-3_0 \
          --application-mode INTERACTIVE \
          --service-execution-role "$ROLE" \
          --application-configuration "$APP_CONFIG" 2>&1)
        status=$?
        set -e

        if [ "$status" -eq 0 ]; then
          echo "$output"
          exit 0
        fi

        echo "$output" >&2
        if ! echo "$output" | grep -Eq "ServiceExecutionRole has insufficient permission|Cannot find database with name"; then
          exit "$status"
        fi

        if [ "$attempt" -lt 12 ]; then
          echo "IAM/Glue configuration is still propagating; retrying Flink creation in 10 seconds ($attempt/12)" >&2
          sleep 10
        fi
      done

      echo "Flink Studio creation failed after waiting for IAM/Glue propagation" >&2
      exit 1
    EOT
  }

  depends_on = [
    aws_glue_catalog_database.flink,
    aws_iam_role_policy.flink
  ]
}

output "alb_dns" { value = aws_lb.main.dns_name }
output "stream_name" { value = aws_kinesis_stream.orders.name }
output "flink_app" { value = "wsc2026-analytics-flink" }
