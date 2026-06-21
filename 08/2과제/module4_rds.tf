# =============================================================================
# Module 4. RDS Connection (Aurora MySQL Serverless v2 + Data API + Lambda)
#  Region: ap-northeast-3
#  - Aurora MySQL Serverless v2 (0.5~4 ACU), DB appdb, master admin
#  - Data API(HTTP Endpoint) Enabled, Secret rds/aurora/admin
#  - Lambda rds-query-function (py3.12, env CLUSTER_ARN/SECRET_ARN/DB_NAME, VPC 없음)
# =============================================================================

locals {
  rds_db_name      = "appdb"
  rds_master_user  = "admin"
  rds_secret_name  = "rds/aurora/admin"
  rds_cluster_name = "rds-aurora-cluster"
}

# Aurora MySQL 3.x (MySQL 8.0 호환) 최신 엔진 버전 조회
data "aws_rds_engine_version" "aurora_mysql" {
  provider             = aws.osaka
  engine               = "aurora-mysql"
  preferred_versions   = ["8.0.mysql_aurora.3.08.0", "8.0.mysql_aurora.3.07.1", "8.0.mysql_aurora.3.07.0"]
  include_all          = true
}

# ---- 네트워크 (ap-northeast-3에 기본 VPC가 없어 Aurora용 전용 VPC/서브넷 구성) ----
# Data API는 퍼블릭 HTTPS 엔드포인트를 사용하므로 IGW/NAT 없이 프라이빗 서브넷이면 충분.
data "aws_availability_zones" "osaka" {
  provider = aws.osaka
  state    = "available"
}

resource "aws_vpc" "rds" {
  provider             = aws.osaka
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name   = "rds-aurora-vpc"
    Module = "RDSConnection"
  }
}

resource "aws_subnet" "rds" {
  provider          = aws.osaka
  count             = 2
  vpc_id            = aws_vpc.rds.id
  cidr_block        = cidrsubnet(aws_vpc.rds.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.osaka.names[count.index]

  tags = {
    Name   = "rds-aurora-subnet-${count.index + 1}"
    Module = "RDSConnection"
  }
}

resource "aws_db_subnet_group" "rds" {
  provider   = aws.osaka
  name       = "rds-aurora-subnet-group"
  subnet_ids = aws_subnet.rds[*].id

  tags = {
    Module = "RDSConnection"
  }
}

# ---- 마스터 암호 ----
resource "random_password" "rds_master" {
  length           = 20
  special          = true
  override_special = "!#$%^&*()-_=+"
}

# ---- Secrets Manager: rds/aurora/admin ----
resource "aws_secretsmanager_secret" "rds" {
  provider                = aws.osaka
  name                    = local.rds_secret_name
  description             = "Aurora admin credentials for WSC 2026"
  recovery_window_in_days = 0

  tags = {
    Module = "RDSConnection"
  }
}

resource "aws_secretsmanager_secret_version" "rds" {
  provider  = aws.osaka
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
  provider = aws.osaka

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

  tags = {
    Module = "RDSConnection"
  }
}

resource "aws_rds_cluster_instance" "aurora" {
  provider = aws.osaka

  identifier         = "${local.rds_cluster_name}-instance-1"
  cluster_identifier = aws_rds_cluster.aurora.id
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version
  instance_class     = "db.serverless"

  tags = {
    Module = "RDSConnection"
  }
}

# ---- Lambda 실행 역할 ----
resource "aws_iam_role" "rds_lambda" {
  provider           = aws.osaka
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
  provider = aws.osaka
  name     = "rds-query-function-policy"
  role     = aws_iam_role.rds_lambda.id
  policy   = data.aws_iam_policy_document.rds_lambda.json
}

# ---- Lambda 패키지 ----
data "archive_file" "rds_lambda" {
  type        = "zip"
  source_file = "${path.module}/files/rds/lambda_function.py"
  output_path = "${path.module}/build/rds_lambda.zip"
}

resource "aws_lambda_function" "rds_query" {
  provider         = aws.osaka
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

  tags = {
    Module = "RDSConnection"
  }

  depends_on = [
    aws_iam_role_policy.rds_lambda,
    aws_rds_cluster_instance.aurora
  ]
}
