locals {
  ecr_url = {
    for k, v in aws_ecr_repository.this : k => v.repository_url
  }
}

# ---------- user ----------
resource "kubernetes_service_account" "user" {
  metadata {
    name      = "user"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
}

resource "kubernetes_deployment" "user" {
  metadata {
    name      = "user"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "user" }
  }
  spec {
    replicas = 2
    selector { match_labels = { app = "user" } }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "25%"
        max_unavailable = "0"
      }
    }
    template {
      metadata {
        labels = { app = "user" }
        # DB 엔드포인트가 바뀌면 파드 템플릿이 바뀌어 롤링 재배포된다.
        # env_from(Secret) 은 실행 중 파드에 자동 반영되지 않아, 이 어노테이션이 없으면
        # apply 후에도 옛 MYSQL_HOST 를 계속 써서 DNS 실패로 500 을 쏟는다.
        annotations = { "wsi/db-host" = aws_db_proxy.this.endpoint }
      }
      spec {
        termination_grace_period_seconds = 35
        service_account_name             = kubernetes_service_account.user.metadata[0].name
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector { match_labels = { app = "user" } }
        }
        # 노드 단위 분산. zone 만으로는 같은 AZ 안에서 한 노드에 다 몰릴 수 있고,
        # 그 노드가 Karpenter 에 회수되면 앱이 통째로 끊긴다(실측: 앱 파드 3개가 한 노드 집중).
        # ScheduleAnyway 라 노드가 부족할 때 스케줄을 막지는 않는다(가용성 우선).
        topology_spread_constraint {
          max_skew           = 3
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector { match_labels = { app = "user" } }
        }
        container {
          name              = "user"
          image             = "${local.ecr_url["user"]}:${local.app_image_tags["user"]}"
          image_pull_policy = "IfNotPresent"
          port { container_port = var.container_port }
          env_from {
            secret_ref { name = kubernetes_secret.db.metadata[0].name }
          }
          env_from {
            config_map_ref { name = kubernetes_config_map.s3.metadata[0].name }
          }
          resources {
            # no cpu limit: CFS throttling wrecks tail latency; memory limit only
            requests = { cpu = "200m", memory = "128Mi" }
            limits   = { memory = "256Mi" }
          }
          readiness_probe {
            http_get {
              path = var.healthcheck_path
              port = var.container_port
            }
            period_seconds    = 5
            failure_threshold = 3
          }
          liveness_probe {
            http_get {
              path = var.healthcheck_path
              port = var.container_port
            }
            period_seconds    = 10
            failure_threshold = 3
          }
        }
      }
    }
  }
  wait_for_rollout = false
  depends_on       = [kubernetes_job.db_init, null_resource.build_push]
}

resource "kubernetes_service" "user" {
  metadata {
    name      = "user"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    selector = { app = "user" }
    port {
      port        = 80
      target_port = var.container_port
      node_port   = 30080
    }
    type = "NodePort"
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "user" {
  metadata {
    name      = "user"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    # PDB(minAvailable=1) 와 짝. replica 가 1 이면 PDB 가 evict 를 전면 차단해
    # Karpenter 가 그 노드를 영구히 회수하지 못하고(비용↑), 노드가 강제 종료되면
    # 대체 파드가 뜨는 동안 서비스가 끊긴다. 2 이면 hostname spread 로 두 노드에 나뉘어
    # 한 노드가 빠져도 무중단이고 consolidation 도 정상 동작한다.
    min_replicas = 2
    max_replicas = 6
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.user.metadata[0].name
    }
    behavior {
      scale_up {
        # 30s 완충: 순간 스파이크로는 안 늘리고, 부하가 "지속"될 때만 확장.
        # (0 이면 CPU 튀자마자 파드 2배 → 노드 폭증의 주범이었음)
        stabilization_window_seconds = 30
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50 # 15초마다 최대 +50% (기존 100% = 2배씩)
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 2 # 15초마다 최대 +2개 (기존 4)
          period_seconds = 15
        }
      }
      scale_down {
        stabilization_window_seconds = 90
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50
          period_seconds = 30
        }
      }
    }
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          # 60%: CPU가 더 차야 확장 → 파드/노드 덜 늘어남 (55는 과민했음).
          # 꼬리지연 생기면 그 앱만 낮추기 — advise.py/autotune 이 판정해줌.
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }
  depends_on = [aws_eks_addon.metrics_server]
}

# ---------- product ----------
resource "kubernetes_service_account" "product" {
  metadata {
    name      = "product"
    namespace = kubernetes_namespace.app.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.product_app.arn
    }
  }
}

resource "kubernetes_deployment" "product" {
  metadata {
    name      = "product"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "product" }
  }
  spec {
    replicas = 2
    selector { match_labels = { app = "product" } }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "25%"
        max_unavailable = "0"
      }
    }
    template {
      metadata {
        labels = { app = "product" }
        # DB 엔드포인트 변경 시 롤링 재배포 유도 (user 와 동일한 이유)
        annotations = { "wsi/db-host" = aws_db_proxy.this.endpoint }
      }
      spec {
        termination_grace_period_seconds = 35
        service_account_name             = kubernetes_service_account.product.metadata[0].name
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector { match_labels = { app = "product" } }
        }
        # 노드 단위 분산. zone 만으로는 같은 AZ 안에서 한 노드에 다 몰릴 수 있고,
        # 그 노드가 Karpenter 에 회수되면 앱이 통째로 끊긴다(실측: 앱 파드 3개가 한 노드 집중).
        # ScheduleAnyway 라 노드가 부족할 때 스케줄을 막지는 않는다(가용성 우선).
        topology_spread_constraint {
          max_skew           = 3
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector { match_labels = { app = "product" } }
        }
        container {
          name              = "product"
          image             = "${local.ecr_url["product"]}:${local.app_image_tags["product"]}"
          image_pull_policy = "IfNotPresent"
          port { container_port = var.container_port }
          env_from {
            secret_ref { name = kubernetes_secret.db.metadata[0].name }
          }
          env_from {
            config_map_ref { name = kubernetes_config_map.s3.metadata[0].name }
          }
          resources {
            # no cpu limit: CFS throttling wrecks tail latency; memory limit only
            requests = { cpu = "200m", memory = "128Mi" }
            limits   = { memory = "512Mi" }
          }
          readiness_probe {
            http_get {
              path = var.healthcheck_path
              port = var.container_port
            }
            period_seconds    = 5
            failure_threshold = 3
          }
          liveness_probe {
            http_get {
              path = var.healthcheck_path
              port = var.container_port
            }
            period_seconds    = 10
            failure_threshold = 3
          }
        }
      }
    }
  }
  wait_for_rollout = false
  depends_on       = [kubernetes_job.db_init, null_resource.build_push]
}

resource "kubernetes_service" "product" {
  metadata {
    name      = "product"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    selector = { app = "product" }
    port {
      port        = 80
      target_port = var.container_port
      node_port   = 30081
    }
    type = "NodePort"
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "product" {
  metadata {
    name      = "product"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    # PDB(minAvailable=1) 와 짝. replica 가 1 이면 PDB 가 evict 를 전면 차단해
    # Karpenter 가 그 노드를 영구히 회수하지 못하고(비용↑), 노드가 강제 종료되면
    # 대체 파드가 뜨는 동안 서비스가 끊긴다. 2 이면 hostname spread 로 두 노드에 나뉘어
    # 한 노드가 빠져도 무중단이고 consolidation 도 정상 동작한다.
    min_replicas = 2
    max_replicas = 6
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.product.metadata[0].name
    }
    behavior {
      scale_up {
        # 30s 완충: 순간 스파이크로는 안 늘리고, 부하가 "지속"될 때만 확장.
        # (0 이면 CPU 튀자마자 파드 2배 → 노드 폭증의 주범이었음)
        stabilization_window_seconds = 30
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50 # 15초마다 최대 +50% (기존 100% = 2배씩)
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 2 # 15초마다 최대 +2개 (기존 4)
          period_seconds = 15
        }
      }
      scale_down {
        stabilization_window_seconds = 90
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50
          period_seconds = 30
        }
      }
    }
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          # 60%: CPU가 더 차야 확장 → 파드/노드 덜 늘어남 (55는 과민했음).
          # 꼬리지연 생기면 그 앱만 낮추기 — advise.py/autotune 이 판정해줌.
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }
  depends_on = [aws_eks_addon.metrics_server]
}

# ---------- stress ----------
resource "kubernetes_service_account" "stress" {
  metadata {
    name      = "stress"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
}

resource "kubernetes_deployment" "stress" {
  metadata {
    name      = "stress"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "stress" }
  }
  spec {
    replicas = 2
    selector { match_labels = { app = "stress" } }
    template {
      metadata { labels = { app = "stress" } }
      spec {
        termination_grace_period_seconds = 35
        service_account_name             = kubernetes_service_account.stress.metadata[0].name
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector { match_labels = { app = "stress" } }
        }
        # 노드 단위 분산. zone 만으로는 같은 AZ 안에서 한 노드에 다 몰릴 수 있고,
        # 그 노드가 Karpenter 에 회수되면 앱이 통째로 끊긴다(실측: 앱 파드 3개가 한 노드 집중).
        # ScheduleAnyway 라 노드가 부족할 때 스케줄을 막지는 않는다(가용성 우선).
        topology_spread_constraint {
          max_skew           = 3
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector { match_labels = { app = "stress" } }
        }
        container {
          name              = "stress"
          image             = "${local.ecr_url["stress"]}:${local.app_image_tags["stress"]}"
          image_pull_policy = "IfNotPresent"
          port { container_port = var.container_port }
          resources {
            # robust default — NOT app-tuned. Re-derive per app with
            # tuning/autotune.sh on competition day (app behavior varies).
            requests = { cpu = "500m", memory = "128Mi" }
            # cpu limit: stress 는 CPU 를 무제한 태워 같은 노드의 user/product 를 굶긴다.
            # (노드 CPU 89~97% / RDS 5~10% → 지연 원인은 노드 CPU 경쟁)
            # stress SLO 1000ms 는 느슨하므로 여기를 캡해 user 200ms 를 지킨다.
            limits = { cpu = "1000m", memory = "512Mi" }
          }
          readiness_probe {
            http_get {
              path = var.healthcheck_path
              port = var.container_port
            }
            period_seconds = 5
          }
          liveness_probe {
            http_get {
              path = var.healthcheck_path
              port = var.container_port
            }
            period_seconds = 10
          }
        }
      }
    }
  }
  wait_for_rollout = false
  depends_on       = [aws_eks_node_group.main, null_resource.build_push]
}

resource "kubernetes_service" "stress" {
  metadata {
    name      = "stress"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    selector = { app = "stress" }
    port {
      port        = 80
      target_port = var.container_port
      node_port   = 30082
    }
    type = "NodePort"
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "stress" {
  metadata {
    name      = "stress"
    namespace = kubernetes_namespace.app.metadata[0].name
  }
  spec {
    # PDB(minAvailable=1) 와 짝. replica 가 1 이면 PDB 가 evict 를 전면 차단해
    # Karpenter 가 그 노드를 영구히 회수하지 못하고(비용↑), 노드가 강제 종료되면
    # 대체 파드가 뜨는 동안 서비스가 끊긴다. 2 이면 hostname spread 로 두 노드에 나뉘어
    # 한 노드가 빠져도 무중단이고 consolidation 도 정상 동작한다.
    min_replicas = 2
    max_replicas = 6
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.stress.metadata[0].name
    }
    behavior {
      scale_up {
        # 30s 완충: 순간 스파이크로는 안 늘리고, 부하가 "지속"될 때만 확장.
        # (0 이면 CPU 튀자마자 파드 2배 → 노드 폭증의 주범이었음)
        stabilization_window_seconds = 30
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50 # 15초마다 최대 +50% (기존 100% = 2배씩)
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 2 # 15초마다 최대 +2개 (기존 4)
          period_seconds = 15
        }
      }
      scale_down {
        stabilization_window_seconds = 90
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 50
          period_seconds = 30
        }
      }
    }
    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          # 60%: CPU가 더 차야 확장 → 파드/노드 덜 늘어남 (55는 과민했음).
          # 꼬리지연 생기면 그 앱만 낮추기 — advise.py/autotune 이 판정해줌.
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }
  }
  depends_on = [aws_eks_addon.metrics_server]
}
