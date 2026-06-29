terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.80" }
    archive = { source = "hashicorp/archive", version = ">= 2.0" }
    null    = { source = "hashicorp/null", version = ">= 3.0" }
  }
}

provider "aws" { region = "ap-northeast-1" }

data "aws_caller_identity" "current" {}
locals {
  region = "ap-northeast-1"
  azs    = ["ap-northeast-1a", "ap-northeast-1c"]
}

# VPC
resource "aws_vpc" "db" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "wsc2026-db-vpc" }
}

resource "aws_subnet" "db_a" {
  vpc_id            = aws_vpc.db.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = local.azs[0]
  tags              = { Name = "wsc2026-db-sn-a" }
}
resource "aws_subnet" "db_c" {
  vpc_id            = aws_vpc.db.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = local.azs[1]
  tags              = { Name = "wsc2026-db-sn-c" }
}
resource "aws_subnet" "pub_a" {
  vpc_id                  = aws_vpc.db.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "wsc2026-pub-sn-a" }
}
resource "aws_subnet" "pub_c" {
  vpc_id                  = aws_vpc.db.id
  cidr_block              = "10.0.4.0/24"
  availability_zone       = local.azs[1]
  map_public_ip_on_launch = true
  tags                    = { Name = "wsc2026-pub-sn-c" }
}

resource "aws_internet_gateway" "db" {
  vpc_id = aws_vpc.db.id
  tags   = { Name = "wsc2026-db-igw" }
}

resource "aws_route_table" "pub" {
  vpc_id = aws_vpc.db.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.db.id
  }
  tags = { Name = "wsc2026-pub-rt" }
}
resource "aws_route_table_association" "pub_a" {
  subnet_id      = aws_subnet.pub_a.id
  route_table_id = aws_route_table.pub.id
}
resource "aws_route_table_association" "pub_c" {
  subnet_id      = aws_subnet.pub_c.id
  route_table_id = aws_route_table.pub.id
}

# Security Groups
resource "aws_security_group" "rds" {
  name   = "wsc2026-rds-sg"
  vpc_id = aws_vpc.db.id
  ingress {
    from_port   = 3306
    to_port     = 3306
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

resource "aws_security_group" "lambda" {
  name   = "wsc2026-lambda-sg"
  vpc_id = aws_vpc.db.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS Subnet Group
resource "aws_db_subnet_group" "db" {
  name       = "wsc2026-db-subnet-group"
  subnet_ids = [aws_subnet.db_a.id, aws_subnet.db_c.id]
}

# RDS Instance
resource "aws_db_instance" "mysql" {
  identifier             = "wsc2026-rds-instance"
  engine                 = "mysql"
  engine_version         = "8.4.9"
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  username               = "admin"
  password               = "Wsc2026Admin!"
  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  skip_final_snapshot    = true
  multi_az               = false
  tags                   = { Name = "wsc2026-rds-instance" }
}

# Secrets Manager
resource "aws_secretsmanager_secret" "rds" {
  name                    = "wsc2026-rds-secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "rds" {
  secret_id = aws_secretsmanager_secret.rds.id
  secret_string = jsonencode({
    username = "admin"
    password = "Wsc2026Admin!"
    engine   = "mysql"
    host     = aws_db_instance.mysql.address
    port     = 3306
    dbname   = "data"
  })
}

# RDS Proxy IAM
resource "aws_iam_role" "proxy" {
  name = "wsc2026-rds-proxy-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "rds.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "proxy" {
  name = "secrets"
  role = aws_iam_role.proxy.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], Resource = aws_secretsmanager_secret.rds.arn }]
  })
}

# RDS Proxy
resource "aws_db_proxy" "proxy" {
  name                   = "wsc2026-rds-proxy"
  engine_family          = "MYSQL"
  role_arn               = aws_iam_role.proxy.arn
  vpc_subnet_ids         = [aws_subnet.db_a.id, aws_subnet.db_c.id]
  vpc_security_group_ids = [aws_security_group.rds.id]
  require_tls            = false

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_secretsmanager_secret.rds.arn
  }

  depends_on = [aws_secretsmanager_secret_version.rds]
}

resource "aws_db_proxy_default_target_group" "proxy" {
  db_proxy_name = aws_db_proxy.proxy.name
}

resource "aws_db_proxy_target" "proxy" {
  db_proxy_name          = aws_db_proxy.proxy.name
  target_group_name      = aws_db_proxy_default_target_group.proxy.name
  db_instance_identifier = aws_db_instance.mysql.identifier
}



# Lambda Layer (pymysql) - build locally
resource "null_resource" "pymysql_layer" {
  triggers = { always = timestamp() }
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      dir="${path.module}/layer"
      rm -rf "$dir"
      mkdir -p "$dir/python"
      pip3 install pymysql -t "$dir/python" --quiet
      (cd "$dir" && zip -r "${path.module}/pymysql-layer.zip" python > /dev/null)
    EOT
  }
}

resource "aws_lambda_layer_version" "pymysql" {
  filename            = "${path.module}/pymysql-layer.zip"
  layer_name          = "pymysql"
  compatible_runtimes = ["python3.14"]
  depends_on          = [null_resource.pymysql_layer]
}

# Lambda IAM
resource "aws_iam_role" "lambda" {
  name = "wsc2026-db-client-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Lambda
data "archive_file" "db_client" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/db_client.zip"
}

resource "aws_lambda_function" "db_client" {
  function_name    = "wsc2026-db-client"
  role             = aws_iam_role.lambda.arn
  handler          = "db_client.lambda_handler"
  runtime          = "python3.14"
  filename         = data.archive_file.db_client.output_path
  source_code_hash = data.archive_file.db_client.output_base64sha256
  timeout          = 30
  layers           = [aws_lambda_layer_version.pymysql.arn]

  vpc_config {
    subnet_ids         = [aws_subnet.db_a.id, aws_subnet.db_c.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_HOST     = aws_db_proxy.proxy.endpoint
      DB_USER     = "admin"
      DB_PASSWORD = "Wsc2026Admin!"
    }
  }

  depends_on = [aws_db_proxy_target.proxy]
}

output "rds_endpoint" { value = aws_db_instance.mysql.endpoint }
output "proxy_endpoint" { value = aws_db_proxy.proxy.endpoint }




