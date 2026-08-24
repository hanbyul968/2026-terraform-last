resource "random_password" "db" {
  length  = 24
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-db-subnets"
  subnet_ids = aws_subnet.public[*].id
  tags       = { Name = "${local.name}-db-subnets" }
}

resource "aws_security_group" "rds" {
  name        = "${local.name}-rds-sg"
  description = "RDS access from EKS nodes"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "MySQL from anywhere in VPC (EKS nodes use cluster-managed SG)"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Custom parameter group: tuned for read-heavy product GETs and many short connections
resource "aws_db_parameter_group" "mysql8" {
  name        = "${local.name}-mysql8"
  family      = "mysql8.0"
  description = "Tuned for ${local.name}"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }
  parameter {
    name  = "collation_server"
    value = "utf8mb4_unicode_ci"
  }
  parameter {
    name  = "time_zone"
    value = "Asia/Seoul"
  }
  parameter {
    name  = "max_connections"
    value = "300"
  }
  parameter {
    name  = "slow_query_log"
    value = "1"
  }
  parameter {
    name  = "long_query_time"
    value = "1"
  }

  # ---------- 성능 우선 튜닝 ----------
  # 전제(실측): DB 는 병목이 아니었다. QueryDatabaseResponseLatency 6.9ms,
  # ReadLatency 0.5~1.3ms, WriteLatency 1.3ms, DB CPU 14%, slow query log 비어 있음.
  # 따라서 여기서 짜낼 수 있는 건 '쿼리 시간'이 아니라 커밋 지연과 커넥션 비용이다.

  # 커밋 지연: 기본값 1 은 매 커밋마다 redo 로그를 디스크에 flush 한다(fsync).
  # 2 는 1초에 한 번 flush → POST /v1/user 같은 쓰기의 응답시간이 줄어든다.
  # ⚠ 내구성 트레이드오프: 인스턴스가 죽으면 최대 1초 분량의 커밋이 유실될 수 있다.
  #    Multi-AZ 동기 복제는 그대로라 스탠바이 전환 자체는 안전하다.
  #    성능 최우선 요청에 따라 켠다. 되돌리려면 값을 "1" 로 바꾼다.
  parameter {
    name  = "innodb_flush_log_at_trx_commit"
    value = "2"
  }

  # binlog fsync 를 매 트랜잭션마다 하지 않는다(같은 계열의 커밋 지연 절감).
  # 이 과제는 binlog 를 복제/복구에 쓰지 않으므로 손실 위험이 실질적으로 없다.
  parameter {
    name  = "sync_binlog"
    value = "0"
  }

  # 앱이 커넥션을 자주 열고 닫으면(go-sql-driver 기본 MaxIdleConns=2) 커넥션 생성
  # 비용이 지연으로 나타난다. 스레드를 캐시해 재사용한다.
  # 실측: ClientConnections 27 -> 208 로 급증했다(커넥션 처닝 근거).
  parameter {
    name  = "thread_cache_size"
    value = "64"
  }

  # 조회는 PK/인덱스 단건 위주다. 테이블/인덱스 핸들 캐시를 넉넉히 둬서
  # 동시 커넥션이 늘어도 open table 경합이 생기지 않게 한다.
  parameter {
    name  = "table_open_cache"
    value = "2000"
  }
}

resource "aws_db_instance" "this" {
  identifier        = "apdev-rds-instance"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp3"
  multi_az          = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result
  port     = 3306

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.mysql8.name

  backup_retention_period         = 1
  backup_window                   = "17:00-18:00"
  maintenance_window              = "sun:18:30-sun:19:30"
  skip_final_snapshot             = true
  apply_immediately               = true
  publicly_accessible             = false
  storage_encrypted               = true
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring.arn
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]
  auto_minor_version_upgrade      = false
  deletion_protection             = false

  tags = { Name = "apdev-rds-instance" }
}

resource "aws_iam_role" "rds_monitoring" {
  name = "${local.name}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
