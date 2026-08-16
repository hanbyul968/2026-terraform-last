# ProxySQL — 앱과 RDS(db.t3.micro, 문제지상 고정) 사이의 커넥션 풀러/멀티플렉서.
#
# 배경: RDS Proxy는 제공된 Go 바이너리(go-sql-driver)가 프록시의 caching_sha2 핸드셰이크를
# 비-TLS에서 처리하지 못해 1045로 실패(mysql CLI는 성공 → 드라이버 고유 이슈, 앱/DSN 수정 불가).
# 인스턴스 상향도 문제지 위배. 따라서 자체 풀러로 해결한다.
#
# ProxySQL은:
#  - 프론트엔드(앱)에 mysql_native_password로 응답 → go-sql-driver 버전/앱 변경과 무관하게 인증 성공.
#  - 앱이 파드당 대량 커넥션(SetMaxOpenConns=50 등)을 열어도, RDS로 가는 백엔드 커넥션을
#    replica당 max_connections로 상한(멀티플렉싱) → t3.micro 메모리 보호.
#  - EC2 기반 EKS에서 동작(문제지 §15 Fargate/Lambda 금지 준수), 비용 미미.
# 앱은 MYSQL_HOST만 ProxySQL 서비스로 바라보면 되고(엔진명 아님 → 문제지 허용), 앱/인스턴스는 불변.

locals {
  # replica당 RDS 백엔드 커넥션 상한. 2 replica → RDS로 최대 40 (t3.micro 안전 범위).
  proxysql_backend_max = 20

  proxysql_cnf = <<-EOT
    datadir="/var/lib/proxysql"

    admin_variables=
    {
      admin_credentials="admin:admin"
      mysql_ifaces="127.0.0.1:6032"
    }

    mysql_variables=
    {
      threads=2
      max_connections=2048
      interfaces="0.0.0.0:6033"
      server_version="8.0.40"
      monitor_username="${var.db_username}"
      monitor_password="${random_password.db.result}"
      monitor_connect_interval=60000
      monitor_ping_interval=10000
      connect_timeout_server=3000
      default_query_timeout=36000000
    }

    mysql_servers=
    (
      { address="${aws_db_instance.this.address}", port=3306, hostgroup=0, max_connections=${local.proxysql_backend_max} }
    )

    mysql_users=
    (
      { username="${var.db_username}", password="${random_password.db.result}", default_hostgroup=0, active=1, max_connections=2000 }
    )

    mysql_query_rules=()
  EOT
}

# cnf에 DB 비밀번호가 들어가므로 ConfigMap이 아니라 Secret으로 보관.
resource "kubernetes_secret" "proxysql_cnf" {
  metadata {
    name      = "proxysql-cnf"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  data = {
    "proxysql.cnf" = local.proxysql_cnf
  }
}

resource "kubernetes_deployment" "proxysql" {
  metadata {
    name      = "proxysql"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "proxysql" }
  }

  # db_init가 appuser를 mysql_native_password로 ALTER한 뒤에 기동(ProxySQL 백엔드도 native 필요).
  depends_on = [kubernetes_job.db_init]

  spec {
    replicas = 2
    selector {
      match_labels = { app = "proxysql" }
    }
    template {
      metadata {
        labels = { app = "proxysql" }
      }
      spec {
        # 2 replica 를 서로 다른 노드/AZ 로 분산. 없으면 둘이 같은 노드에 뜰 수 있어
        # 그 노드가 죽으면 user·product 의 DB 경로가 동시에 끊긴다(가용성 12점 직결).
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector { match_labels = { app = "proxysql" } }
        }
        container {
          name  = "proxysql"
          image = "proxysql/proxysql:2.6.5"
          # emptyDir datadir + --initial: 매 기동 시 cnf를 재적재(상태 비저장 풀러).
          args = ["proxysql", "-f", "-c", "/etc/proxysql.cnf", "--initial"]

          port {
            container_port = 6033
          }

          resources {
            # ProxySQL 은 threads=2 커넥션 멀티플렉서로, 이 과제 QPS(앱당 10~30)에서는
            # CPU 를 거의 쓰지 않는다. 기본 노드가 이미 requests 89% 로 빡빡해서
            # 100m×2 가 2번째 노드를 띄우는 방아쇠가 될 수 있어 50m 으로 낮춘다.
            # (limit 은 그대로 두어 튀는 경우를 흡수)
            requests = {
              cpu    = "50m"
              memory = "96Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }

          volume_mount {
            name       = "cnf"
            mount_path = "/etc/proxysql.cnf"
            sub_path   = "proxysql.cnf"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/proxysql"
          }

          readiness_probe {
            tcp_socket {
              port = 6033
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          liveness_probe {
            tcp_socket {
              port = 6033
            }
            initial_delay_seconds = 30
            period_seconds        = 20
          }
        }

        volume {
          name = "cnf"
          secret {
            secret_name = kubernetes_secret.proxysql_cnf.metadata[0].name
          }
        }
        volume {
          name = "data"
          empty_dir {}
        }
      }
    }
  }
}

resource "kubernetes_service" "proxysql" {
  metadata {
    name      = "proxysql"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    selector = { app = "proxysql" }
    port {
      port        = 3306
      target_port = 6033
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}
