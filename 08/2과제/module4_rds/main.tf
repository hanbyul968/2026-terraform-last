# =============================================================================
# Module 4. RDS Connection (Aurora MySQL Serverless v2 + Data API + Lambda)
#  Region: ap-northeast-3 (오사카)
#  - 독립 루트(self-contained root). Aurora 프로비저닝은 RDS API + Data API(퍼블릭
#    HTTPS)만 사용하므로 in-VPC 접속이 필요 없지만, 본 과제는 전용 VPC를 생성하는
#    모듈이라 배포는 Bastion(Linux)에서 수행하도록 분리했다. (로컬 apply 도 가능)
#  - Aurora MySQL Serverless v2 (0.5~4 ACU), DB appdb, master admin
#  - Data API(HTTP Endpoint) Enabled, Secret rds/aurora/admin
#  - Lambda rds-query-function (py3.12, env CLUSTER_ARN/SECRET_ARN/DB_NAME, VPC 없음)
#  - Tag: Module=RDSConnection
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = "ap-northeast-3"

  default_tags {
    tags = {
      Project = "wsc2026-task2"
      Module  = "RDSConnection"
    }
  }
}

locals {
  rds_db_name      = "appdb"
  rds_master_user  = "admin"
  rds_secret_name  = "rds/aurora/admin"
  rds_cluster_name = "rds-aurora-cluster"
}

# Aurora MySQL 3.x (MySQL 8.0 호환) 최신 엔진 버전 조회 (3.07 이상)
data "aws_rds_engine_version" "aurora_mysql" {
  engine             = "aurora-mysql"
  preferred_versions = ["8.0.mysql_aurora.3.08.0", "8.0.mysql_aurora.3.07.1", "8.0.mysql_aurora.3.07.0"]
  include_all        = true
}

# ---- 네트워크 (ap-northeast-3에 기본 VPC가 없어 Aurora용 전용 VPC/서브넷 구성) ----
# Data API는 퍼블릭 HTTPS 엔드포인트를 사용하므로 IGW/NAT 없이 프라이빗 서브넷이면 충분.
data "aws_availability_zones" "osaka" {
  state = "available"
}

resource "aws_vpc" "rds" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "rds-aurora-vpc"
  }
}

resource "aws_subnet" "rds" {
  count             = 2
  vpc_id            = aws_vpc.rds.id
  cidr_block        = cidrsubnet(aws_vpc.rds.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.osaka.names[count.index]

  tags = {
    Name = "rds-aurora-subnet-${count.index + 1}"
  }
}

resource "aws_db_subnet_group" "rds" {
  name       = "rds-aurora-subnet-group"
  subnet_ids = aws_subnet.rds[*].id
}

# ---- 마스터 암호 ----
resource "random_password" "rds_master" {
  length           = 20
  special          = true
  override_special = "!#$%^&*()-_=+"
}

# ---- Secrets Manager: rds/aurora/admin ----
resource "aws_secretsmanager_secret" "rds" {
  name                    = local.rds_secret_name
  description             = "Aurora admin credentials for WSC 2026"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "rds" {
  secret_id = aws_secretsmanager_secret.rds.id
  secret_string = jsonencode({
    username = local.rds_master_user
    password = random_password.rds_master.result
    engine   = "mysql"
    dbname   = local.rds_db_name
  })
}

# ---- Aurora MySQL Serverless v2 클러스터 ----
resource "aws_rds_cluster" "aurora" {
  cluster_identifier   = local.rds_cluster_name
  engine               = "aurora-mysql"
  engine_version       = data.aws_rds_engine_version.aurora_mysql.version
  database_name        = local.rds_db_name
  master_username      = local.rds_master_user
  master_password      = random_password.rds_master.result
  enable_http_endpoint = true # RDS Data API
  db_subnet_group_name = aws_db_subnet_group.rds.name

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 4
  }

  skip_final_snapshot = true
  apply_immediately   = true
}

resource "aws_rds_cluster_instance" "aurora" {
  identifier         = "${local.rds_cluster_name}-instance-1"
  cluster_identifier = aws_rds_cluster.aurora.id
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version
  instance_class     = "db.serverless"
}

# ---- Lambda 실행 역할 ----
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "rds_lambda" {
  name               = "rds-query-function-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "rds_lambda" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
  statement {
    sid       = "RdsData"
    actions   = ["rds-data:ExecuteStatement"]
    resources = [aws_rds_cluster.aurora.arn]
  }
  statement {
    sid       = "SecretRead"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.rds.arn]
  }
}

resource "aws_iam_role_policy" "rds_lambda" {
  name   = "rds-query-function-policy"
  role   = aws_iam_role.rds_lambda.id
  policy = data.aws_iam_policy_document.rds_lambda.json
}

# ---- Lambda 패키지 (지급된 lambda_function.py) ----
data "archive_file" "rds_lambda" {
  type        = "zip"
  source_file = "${path.module}/files/rds/lambda_function.py"
  output_path = "${path.module}/build/rds_lambda.zip"
}

resource "aws_lambda_function" "rds_query" {
  function_name    = "rds-query-function"
  role             = aws_iam_role.rds_lambda.arn
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  timeout          = 60
  filename         = data.archive_file.rds_lambda.output_path
  source_code_hash = data.archive_file.rds_lambda.output_base64sha256

  environment {
    variables = {
      CLUSTER_ARN = aws_rds_cluster.aurora.arn
      SECRET_ARN  = aws_secretsmanager_secret.rds.arn
      DB_NAME     = local.rds_db_name
    }
  }

  depends_on = [
    aws_iam_role_policy.rds_lambda,
    aws_rds_cluster_instance.aurora
  ]
}

# ---- 출력 ----
output "m4_cluster_arn" {
  description = "Aurora 클러스터 ARN"
  value       = aws_rds_cluster.aurora.arn
}

output "m4_secret_arn" {
  description = "Secrets Manager 시크릿 ARN"
  value       = aws_secretsmanager_secret.rds.arn
}

output "m4_lambda_name" {
  description = "RDS 조회 Lambda 이름"
  value       = aws_lambda_function.rds_query.function_name
}
