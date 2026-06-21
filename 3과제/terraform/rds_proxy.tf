# RDS Proxy — 커넥션 풀링. 부하 시 user/product 파드가 HPA로 늘어나도
# (pod × MaxOpenConns) 가 RDS max_connections 를 넘겨 커넥션 폭주로 죽지 않게 한다.
# 앱은 RDS 직접이 아니라 이 Proxy 엔드포인트로 붙는다(k8s_base.tf 의 secret MYSQL_HOST).

# Proxy 는 Secrets Manager 에 저장된 자격증명으로 RDS 에 접속한다.
resource "aws_secretsmanager_secret" "db_proxy" {
  name                    = "${local.name}-db-proxy-cred"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_proxy" {
  secret_id = aws_secretsmanager_secret.db_proxy.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
  })
}

# Proxy 가 Secrets Manager 를 읽을 IAM 역할
data "aws_iam_policy_document" "proxy_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "proxy" {
  name               = "${local.name}-rds-proxy"
  assume_role_policy = data.aws_iam_policy_document.proxy_assume.json
}

resource "aws_iam_role_policy" "proxy" {
  name = "secrets-access"
  role = aws_iam_role.proxy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.db_proxy.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "secretsmanager.${var.region}.amazonaws.com" }
        }
      }
    ]
  })
}

# Proxy 보안그룹: VPC 내부(앱)에서 3306 인입 허용. RDS SG 는 이미 VPC CIDR 3306 허용.
resource "aws_security_group" "proxy" {
  name        = "${local.name}-rds-proxy-sg"
  description = "RDS Proxy ingress from app pods"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "MySQL from VPC (app pods)"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_proxy" "this" {
  name                   = "${local.name}-proxy"
  engine_family          = "MYSQL"
  role_arn               = aws_iam_role.proxy.arn
  vpc_subnet_ids         = aws_subnet.public[*].id
  vpc_security_group_ids = [aws_security_group.proxy.id]
  require_tls            = false
  idle_client_timeout    = 1800

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_secretsmanager_secret.db_proxy.arn
  }
}

resource "aws_db_proxy_default_target_group" "this" {
  db_proxy_name = aws_db_proxy.this.name

  connection_pool_config {
    # RDS max_connections(파라미터그룹 300) 의 100%까지 풀링.
    max_connections_percent      = 100
    max_idle_connections_percent = 50
    connection_borrow_timeout    = 120
  }
}

resource "aws_db_proxy_target" "this" {
  db_proxy_name          = aws_db_proxy.this.name
  target_group_name      = aws_db_proxy_default_target_group.this.name
  db_instance_identifier = aws_db_instance.this.identifier
}
