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
          image             = "${local.ecr_url["user"]}:${var.app_image_tag}"
          image_pull_policy = "Always"
          port { container_port = 8080 }
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
              path = "/healthcheck"
              port = 8080
            }
            period_seconds    = 5
            failure_threshold = 3
          }
          liveness_probe {
            http_get {
              path = "/healthcheck"
              port = 8080
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
      target_port = 8080
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
    min_replicas = 2
    max_replicas = 10
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.user.metadata[0].name
    }
    behavior {
      scale_up {
        stabilization_window_seconds = 0
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 4
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
          type                = "Utilization"
          average_utilization = 55
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
          image             = "${local.ecr_url["product"]}:${var.app_image_tag}"
          image_pull_policy = "Always"
          port { container_port = 8080 }
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
              path = "/healthcheck"
              port = 8080
            }
            period_seconds    = 5
            failure_threshold = 3
          }
          liveness_probe {
            http_get {
              path = "/healthcheck"
              port = 8080
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
      target_port = 8080
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
    min_replicas = 2
    max_replicas = 10
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.product.metadata[0].name
    }
    behavior {
      scale_up {
        stabilization_window_seconds = 0
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 4
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
          type                = "Utilization"
          average_utilization = 55
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
        container {
          name              = "stress"
          image             = "${local.ecr_url["stress"]}:${var.app_image_tag}"
          image_pull_policy = "Always"
          port { container_port = 8080 }
          resources {
            # robust default — NOT app-tuned. Re-derive per app with
            # tuning/autotune.sh on competition day (app behavior varies).
            requests = { cpu = "500m", memory = "128Mi" }
            limits   = { memory = "512Mi" }
          }
          readiness_probe {
            http_get {
              path = "/healthcheck"
              port = 8080
            }
            period_seconds = 5
          }
          liveness_probe {
            http_get {
              path = "/healthcheck"
              port = 8080
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
      target_port = 8080
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
    min_replicas = 2
    max_replicas = 10
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.stress.metadata[0].name
    }
    behavior {
      scale_up {
        stabilization_window_seconds = 0
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 4
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
          type                = "Utilization"
          average_utilization = 55
        }
      }
    }
  }
  depends_on = [aws_eks_addon.metrics_server]
}
