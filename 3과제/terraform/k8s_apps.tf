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
    replicas = 1
    selector { match_labels = { app = "user" } }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "25%"
        max_unavailable = "0"
      }
    }
    template {
      metadata { labels = { app = "user" } }
      spec {
        termination_grace_period_seconds = 35
        service_account_name             = kubernetes_service_account.user.metadata[0].name
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector { match_labels = { app = "user" } }
        }
        container {
          name              = "user"
          image             = "${local.ecr_url["user"]}:${local.app_image_tags["user"]}"
          image_pull_policy = "Always"
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
    min_replicas = 1
    max_replicas = 10
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
          average_utilization = 60
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
    replicas = 1
    selector { match_labels = { app = "product" } }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "25%"
        max_unavailable = "0"
      }
    }
    template {
      metadata { labels = { app = "product" } }
      spec {
        termination_grace_period_seconds = 35
        service_account_name             = kubernetes_service_account.product.metadata[0].name
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector { match_labels = { app = "product" } }
        }
        container {
          name              = "product"
          image             = "${local.ecr_url["product"]}:${local.app_image_tags["product"]}"
          image_pull_policy = "Always"
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
    min_replicas = 1
    max_replicas = 10
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
          average_utilization = 60
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
    replicas = 1
    selector { match_labels = { app = "stress" } }
    template {
      metadata { labels = { app = "stress" } }
      spec {
        termination_grace_period_seconds = 35
        service_account_name             = kubernetes_service_account.stress.metadata[0].name
        container {
          name              = "stress"
          image             = "${local.ecr_url["stress"]}:${local.app_image_tags["stress"]}"
          image_pull_policy = "Always"
          port { container_port = var.container_port }
          resources {
            # robust default — NOT app-tuned. Re-derive per app with
            # tuning/autotune.sh on competition day (app behavior varies).
            requests = { cpu = "500m", memory = "128Mi" }
            limits   = { memory = "512Mi" }
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
    min_replicas = 1
    max_replicas = 10
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
          average_utilization = 60
        }
      }
    }
  }
  depends_on = [aws_eks_addon.metrics_server]
}
