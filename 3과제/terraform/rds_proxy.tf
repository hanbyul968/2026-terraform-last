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

# 자동 교정 스크립트 — terraform 값만 보간하고 셸 변수는 최소화(build.tf 와 동일한 방침).
locals {
  proxy_auth_want = "MYSQL_NATIVE_PASSWORD"

  proxy_auth_cmd_ps = <<-PS
    $ErrorActionPreference='Stop'
    $cur = aws rds describe-db-proxies --db-proxy-name ${local.name}-proxy --region ${var.region} --query "DBProxies[0].Auth[0].ClientPasswordAuthType" --output text
    if ($cur -eq '${local.proxy_auth_want}') { Write-Host "proxy client auth OK ($cur)"; exit 0 }
    Write-Host "proxy client auth = $cur -> ${local.proxy_auth_want} 로 교정"
    $arn = aws rds describe-db-proxies --db-proxy-name ${local.name}-proxy --region ${var.region} --query "DBProxies[0].Auth[0].SecretArn" --output text
    aws rds modify-db-proxy --db-proxy-name ${local.name}-proxy --region ${var.region} --auth "AuthScheme=SECRETS,SecretArn=$arn,IAMAuth=DISABLED,ClientPasswordAuthType=${local.proxy_auth_want}" | Out-Null
    for ($i=0; $i -lt 40; $i++) {
      $st = aws rds describe-db-proxies --db-proxy-name ${local.name}-proxy --region ${var.region} --query "DBProxies[0].Status" --output text
      if ($st -eq 'available') { Write-Host "proxy available"; exit 0 }
      Start-Sleep -Seconds 10
    }
    Write-Error "proxy 가 available 로 돌아오지 않았습니다"
  PS

  proxy_auth_cmd_sh = <<-SH
    set -e
    CUR=$(aws rds describe-db-proxies --db-proxy-name ${local.name}-proxy --region ${var.region} --query "DBProxies[0].Auth[0].ClientPasswordAuthType" --output text)
    if [ "$CUR" = "${local.proxy_auth_want}" ]; then echo "proxy client auth OK ($CUR)"; exit 0; fi
    echo "proxy client auth = $CUR -> ${local.proxy_auth_want} 로 교정"
    ARN=$(aws rds describe-db-proxies --db-proxy-name ${local.name}-proxy --region ${var.region} --query "DBProxies[0].Auth[0].SecretArn" --output text)
    aws rds modify-db-proxy --db-proxy-name ${local.name}-proxy --region ${var.region} --auth "AuthScheme=SECRETS,SecretArn=$ARN,IAMAuth=DISABLED,ClientPasswordAuthType=${local.proxy_auth_want}" >/dev/null
    i=0
    while [ $i -lt 40 ]; do
      ST=$(aws rds describe-db-proxies --db-proxy-name ${local.name}-proxy --region ${var.region} --query "DBProxies[0].Status" --output text)
      if [ "$ST" = "available" ]; then echo "proxy available"; exit 0; fi
      i=$((i+1)); sleep 10
    done
    echo "proxy 가 available 로 돌아오지 않았습니다" >&2; exit 1
  SH
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
}

resource "aws_db_proxy_default_target_group" "this" {
  db_proxy_name = aws_db_proxy.this.name

  connection_pool_config {
    # db.t3.micro(1GB) 보호: 백엔드 커넥션 상한을 낮추고 유휴는 빠르게 회수.
    # 프록시가 다수 클라이언트를 소수 백엔드 커넥션으로 멀티플렉싱하므로 낮아도 된다.
    # max_connections=300 기준 40% = 120. 1GB 에 부담되면 20~30% 로 낮춘다.
    max_connections_percent      = 40
    max_idle_connections_percent = 10
    # 커넥션을 못 얻을 때 대기 상한. 기본 120초는 너무 길다.
    # borrow 대기는 전체 응답시간의 '하한' 이다: borrow 에만 5초를 쓴 요청은 전체가
    # 반드시 5초를 넘고, 채점은 '5초 내 2xx' 이므로 그 요청은 이미 가용성에서 탈락이다.
    # 즉 5초로 자를 때 잃는 요청은 어차피 점수에 못 들어가던 요청뿐이다.
    # 반대로 120초로 두면 실패할 요청이 그 시간만큼 커넥션 슬롯과 고루틴을 붙잡아,
    # 뒤에 줄 선 '성공할 수 있었던' 요청까지 같이 느려진다(연쇄 지연).
    #
    # 주의: 이 값은 프록시가 최대 커넥션 수를 모두 열었을 때만 적용된다.
    # 실측은 120개 중 31개 사용(포화 아님)이라 지금은 발동하지 않는다.
    # 성능 개선책이 아니라 '포화 시 연쇄 지연 차단' 안전장치로 둔다.
    connection_borrow_timeout = 5
  }
}

resource "aws_db_proxy_target" "this" {
  db_proxy_name          = aws_db_proxy.this.name
  target_group_name      = aws_db_proxy_default_target_group.this.name
  db_instance_identifier = aws_db_instance.this.identifier
}

# ---------------------------------------------------------------------------
# 클라이언트 인증 방식 강제 (native) — 자동 교정
#
# 실측: terraform 이 기존 프록시를 수정할 때 client_password_auth_type 이 반영되지 않고
# apply 는 성공해버렸다(AWS 는 MYSQL_CACHING_SHA2_PASSWORD 유지). 그 상태면 제공된 Go
# 바이너리가 Error 1045 로 전부 CrashLoopBackOff 된다.
# provider 동작에 의존하지 않기 위해, 실제 AWS 값을 읽어 다르면 직접 고치고 available 까지
# 기다린다. 이미 native 면 아무 것도 하지 않는다(idempotent).
#
# ⚠ mysql CLI 는 caching_sha2 여도 접속되므로 CLI 검증으로는 이 문제를 잡을 수 없다.
# ---------------------------------------------------------------------------
resource "null_resource" "proxy_client_auth" {
  triggers = {
    proxy = aws_db_proxy.this.name
    # 매 apply 마다 실제 값을 확인한다 (외부에서 바뀌었을 수도 있으므로)
    always = timestamp()
  }

  provisioner "local-exec" {
    interpreter = local.build_interpreter
    environment = local.exec_env
    command     = var.is_windows ? local.proxy_auth_cmd_ps : local.proxy_auth_cmd_sh
  }

  depends_on = [aws_db_proxy_target.this]
}
