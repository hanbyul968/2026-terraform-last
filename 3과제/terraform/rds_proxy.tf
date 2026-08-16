# RDS Proxy — 커넥션 풀링/멀티플렉싱.
# HPA 로 user/product 파드가 늘어나도 (pod × MaxOpenConns) 가 RDS max_connections 를
# 넘겨 커넥션 폭주로 죽지 않게 한다. 앱은 RDS 직결이 아니라 이 Proxy 엔드포인트로 붙는다
# (k8s_base.tf 의 kubernetes_secret.db → MYSQL_HOST).
#
# ⚠ 인증 전제: RDS Proxy 는 caching_sha2_password + require_tls=false 조합에서 1045 로
#    거부한다. k8s_base.tf 의 db-init Job 이 앱 유저를 mysql_native_password 로 ALTER 하므로
#    (RDS 직결로 수행) 프록시 경유 인증이 성립한다. 이 ALTER 가 빠지면 앱 전체가 1045 로 죽는다.
#
# ⚠ 비용: RDS Proxy 는 DB 인스턴스 vCPU 시간당 과금(db.t3.micro = 2 vCPU → 약 $0.03/h).
#    대신 파드 커넥션 풀러를 클러스터에서 없애 노드 CPU/메모리를 아낀다.

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

# Proxy 보안그룹: VPC 내부(앱 파드)에서 3306 인입 허용.
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
  name           = "${local.name}-proxy"
  engine_family  = "MYSQL"
  role_arn       = aws_iam_role.proxy.arn
  vpc_subnet_ids = aws_subnet.public[*].id
  # 제공된 Go 바이너리(go-sql-driver)는 TLS 없이 접속하므로 강제하지 않는다.
  require_tls            = false
  idle_client_timeout    = 1800
  vpc_security_group_ids = [aws_security_group.proxy.id]

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_secretsmanager_secret.db_proxy.arn
    # ★ 이게 없으면 프록시가 클라이언트에 caching_sha2_password 를 제시하고,
    #   제공된 Go 바이너리(go-sql-driver)는 비-TLS 에서 그 방식을 처리하지 못해
    #   "Error 1045 Access denied for user 'appuser'" 로 전부 죽는다.
    #   (mysql CLI 는 성공하므로 CLI 로만 검증하면 놓친다 — 반드시 앱 로그로 확인)
    #   native 로 고정하면 DSN 수정 없이 인증이 통한다.
    client_password_auth_type = "MYSQL_NATIVE_PASSWORD"
  }

  depends_on = [aws_secretsmanager_secret_version.db_proxy]

  # 이 값이 native 가 아니면 앱(go-sql-driver)이 1045 로 전부 죽는다.
  # 실측: terraform 이 기존 프록시를 "수정"할 때는 이 필드를 반영하지 못했다
  # (apply 는 성공했는데 AWS 는 MYSQL_CACHING_SHA2_PASSWORD 유지).
  # mysql CLI 로는 caching_sha2 여도 접속이 되므로 CLI 검증으로는 절대 못 잡는다.
  # → apply 시점에 실제 값을 확인해 조용히 넘어가지 않게 한다.
  lifecycle {
    postcondition {
      condition     = anytrue([for a in self.auth : a.client_password_auth_type == "MYSQL_NATIVE_PASSWORD"])
      error_message = "RDS Proxy client auth 가 MYSQL_NATIVE_PASSWORD 가 아닙니다. 앱이 1045 로 죽습니다. 수정: aws rds modify-db-proxy --db-proxy-name <name> --auth AuthScheme=SECRETS,SecretArn=<arn>,IAMAuth=DISABLED,ClientPasswordAuthType=MYSQL_NATIVE_PASSWORD"
    }
  }
}

resource "aws_db_proxy_default_target_group" "this" {
  db_proxy_name = aws_db_proxy.this.name

  connection_pool_config {
    # db.t3.micro(1GB) 보호: 백엔드 커넥션 상한을 낮추고 유휴는 빠르게 회수.
    # 프록시가 다수 클라이언트를 소수 백엔드 커넥션으로 멀티플렉싱하므로 낮아도 된다.
    # max_connections=300 기준 40% = 120. 1GB 에 부담되면 20~30% 로 낮춘다.
    max_connections_percent      = 40
    max_idle_connections_percent = 10
    connection_borrow_timeout    = 120
  }
}

resource "aws_db_proxy_target" "this" {
  db_proxy_name          = aws_db_proxy.this.name
  target_group_name      = aws_db_proxy_default_target_group.this.name
  db_instance_identifier = aws_db_instance.this.identifier
}
