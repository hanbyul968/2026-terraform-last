resource "kubernetes_namespace" "app" {
  metadata {
    name = "app"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "kubernetes_secret" "db" {
  metadata {
    name      = "db-credentials"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  data = {
    MYSQL_USER     = var.db_username
    MYSQL_PASSWORD = random_password.db.result
    # 앱은 RDS Proxy 경유(local.db_host). 파드가 HPA 로 늘어도 프록시가 백엔드 커넥션을
    # 소수로 멀티플렉싱해 db.t3.micro 의 max_connections 를 지킨다.
    # 엔진명이 아닌 DNS 엔드포인트라 문제지 요구("엔진명 삽입금지")를 만족한다.
    # db_init 는 아래에서 MYSQL_HOST 를 직결 RDS 로 override 하여 스키마/시드를 수행한다.
    MYSQL_HOST   = local.db_host
    MYSQL_PORT   = "3306"
    MYSQL_DBNAME = var.db_name
  }
}

resource "kubernetes_config_map" "s3" {
  metadata {
    name      = "s3-config"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  data = {
    S3_BUCKET  = aws_s3_bucket.images.bucket
    AWS_REGION = var.region
  }
}

# 스키마 SQL 을 ConfigMap 으로 넘긴다 (셸 heredoc 인라인 대신).
# 이유: 대회날 스키마가 바뀌어도 var.db_schema_sql 만 교체하면 되고, 셸 인용/들여쓰기
# 문제로 SQL 이 깨질 위험이 없다.
locals {
  # 조회 컬럼 인덱스 보장 — 테이블이 이미 있어 CREATE TABLE 이 no-op 인 경우에도
  # 인덱스를 확실히 추가한다. information_schema 를 확인하므로 멱등하다.
  # 인덱스가 없으면 풀스캔이 되어 0.2s SLO 를 절대 만족할 수 없다.
  db_index_sql = join("\n", [
    for i in var.db_required_indexes : join("\n", [
      "SET @s = (SELECT IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='${i.table}' AND index_name='${i.index}')=0,",
      "  'ALTER TABLE `${i.table}` ADD INDEX `${i.index}` (`${i.column}`)', 'SELECT 1'));",
      "PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;",
    ])
  ])

  db_init_sql = "${var.db_schema_sql}\n${local.db_index_sql}\n"
}

resource "kubernetes_config_map" "db_schema" {
  metadata {
    name      = "db-schema"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  data = {
    "schema.sql" = local.db_init_sql
  }
}

# Init job: create tables + ensure lookup indexes + load seed dump
resource "kubernetes_job" "db_init" {
  metadata {
    name      = "db-init"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    backoff_limit = 5
    template {
      metadata {
        labels = { job = "db-init" }
      }
      spec {
        restart_policy       = "OnFailure"
        service_account_name = kubernetes_service_account.db_init.metadata[0].name

        # S3 에서 시드 덤프를 받아 공유 볼륨(/seed)에 둔다. 크기 무제한(스트리밍).
        init_container {
          name    = "fetch-seed"
          image   = "amazon/aws-cli:2.15.30"
          command = ["sh", "-c"]
          args    = ["aws s3 cp s3://${aws_s3_bucket.artifacts.bucket}/${aws_s3_object.seed.key} /seed/load_user.dump"]
          env {
            name  = "AWS_REGION"
            value = var.region
          }
          env {
            name  = "AWS_DEFAULT_REGION"
            value = var.region
          }
          volume_mount {
            name       = "seed"
            mount_path = "/seed"
          }
        }

        container {
          name    = "mysql"
          image   = "mysql:8.0"
          command = ["sh", "-c"]
          args = [
            <<-EOT
            set -e
            until mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1"; do
              echo waiting for db; sleep 5
            done
            # RDS Proxy는 caching_sha2_password + require_tls=false 조합에서 1045로 거부한다.
            # 앱 유저를 native password로 바꿔 프록시 경유 인증이 되게 한다(비밀번호는 그대로 유지 → idempotent).
            mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "ALTER USER '$MYSQL_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$MYSQL_PASSWORD';"
            mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DBNAME" < /sql/schema.sql

            # Seed the user table once. Idempotent: only load when the table is
            # empty, so job retries / re-applies never hit PRIMARY KEY conflicts.
            CNT=$(mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -N -B \
              -e "SELECT COUNT(*) FROM \`$MYSQL_DBNAME\`.\`${var.db_seed_table}\`")
            if [ "$CNT" = "0" ]; then
              echo "loading user seed dump..."
              # 덤프에 잘못된 대상 DB(USE `apdev`)가 박혀 있어도 무시하고,
              # mysql CLI 인자로 지정한 올바른 DB($MYSQL_DBNAME)에 적재한다.
              grep -vi '^[[:space:]]*USE[[:space:]]' /seed/load_user.dump | mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DBNAME"
              echo "seed load done"
            else
              echo "user table already has $CNT rows; skipping seed"
            fi

            # ---- 앱이 쓸 DB 주소가 실제로 응답할 때까지 대기 ----
            # RDS 직결이면 이미 준비된 상태라 즉시 통과한다.
            # RDS Proxy 를 켠 경우, terraform 상 생성이 끝나도 타깃이 수분간
            # PENDING_PROXY_CAPACITY 로 남으므로 여기서 막아둔다. 앱 Deployment 는 이 Job 에
            # depends_on 이라, 앱이 붙는 시점에는 항상 준비가 끝나 있다.
            # (헬스체크는 DB 를 보지 않아, 앱이 Ready 로 뜨고 500 을 쏟는 것을 방지)
            i=0
            until mysql -h"$APP_DB_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; do
              i=$((i+1))
              if [ "$i" -gt 120 ]; then
                echo "ERROR: DB($APP_DB_HOST) 로 접속하지 못했습니다 (10분 초과)." >&2
                exit 1
              fi
              echo "waiting for app DB endpoint ($APP_DB_HOST) ... $i"
              sleep 5
            done
            echo "app DB endpoint ready"
            EOT
          ]
          # db_init는 프록시가 아니라 RDS에 직접 접속한다: 프록시 인증을 고치는 ALTER를
          # 프록시 경유로는 실행할 수 없으므로(치킨-에그). 앱만 프록시(secret의 MYSQL_HOST)를 쓴다.
          env {
            name  = "MYSQL_HOST"
            value = aws_db_instance.this.address
          }
          # 위 대기 루프에서 앱이 쓸 엔드포인트 준비 확인에 사용.
          env {
            name  = "APP_DB_HOST"
            value = local.db_host
          }
          env_from {
            secret_ref { name = kubernetes_secret.db.metadata[0].name }
          }
          volume_mount {
            name       = "seed"
            mount_path = "/seed"
            read_only  = true
          }
          volume_mount {
            name       = "sql"
            mount_path = "/sql"
            read_only  = true
          }
        }
        volume {
          name = "seed"
          empty_dir {}
        }
        volume {
          name = "sql"
          config_map {
            name = kubernetes_config_map.db_schema.metadata[0].name
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    # 스키마 + 시드(10MB 덤프) + RDS Proxy 준비 대기(최대 10분)를 모두 포함한다.
    create = "25m"
  }

  depends_on = [aws_db_instance.this, aws_db_proxy_target.this, null_resource.proxy_client_auth, aws_eks_node_group.main, aws_s3_object.seed]
}
