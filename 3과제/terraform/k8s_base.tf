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
    # 앱은 ProxySQL 경유(proxysql.tf). ProxySQL이 프론트엔드에 native 인증 제시(go-sql-driver 무관) +
    # RDS 백엔드 커넥션을 소수로 상한 → t3.micro 보호. 엔진명이 아닌 DNS라 문제지 허용.
    # db_init는 아래에서 MYSQL_HOST를 직결 RDS로 override하여 ALTER/스키마/시드를 직접 수행.
    MYSQL_HOST   = "${kubernetes_service.proxysql.metadata[0].name}.${kubernetes_namespace.app.metadata[0].name}.svc.cluster.local"
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

# Init job: create tables + add email index (spec lets us redesign schema for traffic patterns)
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
            mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DBNAME" <<'SQL'
            CREATE TABLE IF NOT EXISTS user (
              id VARCHAR(255) NOT NULL,
              username VARCHAR(255) NOT NULL,
              email VARCHAR(255) NOT NULL,
              PRIMARY KEY (id),
              UNIQUE KEY uk_username (username),
              KEY idx_email (email)
            );
            CREATE TABLE IF NOT EXISTS product (
              id VARCHAR(255) NOT NULL,
              name VARCHAR(255) NOT NULL,
              price FLOAT(8) NOT NULL,
              image_path VARCHAR(500) DEFAULT NULL,
              PRIMARY KEY (id)
            );
            -- add email index if table preexisted without it (safe no-op if already exists)
            SET @sql = (SELECT IF(
              (SELECT COUNT(*) FROM information_schema.statistics
                WHERE table_schema=DATABASE() AND table_name='user' AND index_name='idx_email')=0,
              'ALTER TABLE user ADD INDEX idx_email (email)',
              'SELECT 1'));
            PREPARE stmt FROM @sql; EXECUTE stmt; DEALLOCATE PREPARE stmt;
            SQL

            # Seed the user table once. Idempotent: only load when the table is
            # empty, so job retries / re-applies never hit PRIMARY KEY conflicts.
            CNT=$(mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -N -B \
              -e "SELECT COUNT(*) FROM \`$MYSQL_DBNAME\`.user")
            if [ "$CNT" = "0" ]; then
              echo "loading user seed dump..."
              # 덤프에 잘못된 대상 DB(USE `apdev`)가 박혀 있어도 무시하고,
              # mysql CLI 인자로 지정한 올바른 DB($MYSQL_DBNAME)에 적재한다.
              grep -vi '^[[:space:]]*USE[[:space:]]' /seed/load_user.dump | mysql -h"$MYSQL_HOST" -P"$MYSQL_PORT" -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DBNAME"
              echo "seed load done"
            else
              echo "user table already has $CNT rows; skipping seed"
            fi
            EOT
          ]
          # db_init는 프록시가 아니라 RDS에 직접 접속한다: 프록시 인증을 고치는 ALTER를
          # 프록시 경유로는 실행할 수 없으므로(치킨-에그). 앱만 프록시(secret의 MYSQL_HOST)를 쓴다.
          env {
            name  = "MYSQL_HOST"
            value = aws_db_instance.this.address
          }
          env_from {
            secret_ref { name = kubernetes_secret.db.metadata[0].name }
          }
          volume_mount {
            name       = "seed"
            mount_path = "/seed"
            read_only  = true
          }
        }
        volume {
          name = "seed"
          empty_dir {}
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "15m"
  }

  depends_on = [aws_db_instance.this, aws_eks_node_group.main, aws_s3_object.seed]
}
