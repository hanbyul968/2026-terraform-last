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
    MYSQL_HOST     = aws_db_instance.this.address
    MYSQL_PORT     = tostring(aws_db_instance.this.port)
    MYSQL_DBNAME   = var.db_name
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
        restart_policy = "OnFailure"
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
            EOT
          ]
          env_from {
            secret_ref { name = kubernetes_secret.db.metadata[0].name }
          }
        }
      }
    }
  }

  wait_for_completion = true
  timeouts {
    create = "10m"
  }

  depends_on = [aws_db_instance.this, aws_eks_node_group.main]
}
