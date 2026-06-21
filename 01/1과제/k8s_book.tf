resource "kubernetes_namespace_v1" "book" {
  metadata { name = "book" }
  depends_on = [aws_eks_node_group.app, aws_eks_node_group.addon]
}

resource "kubernetes_service_account_v1" "book" {
  metadata {
    name      = "book-sa"
    namespace = kubernetes_namespace_v1.book.metadata[0].name
  }
}

resource "kubernetes_stateful_set_v1" "book" {
  metadata {
    name      = "book"
    namespace = kubernetes_namespace_v1.book.metadata[0].name
    labels    = { app = "book" }
  }

  spec {
    service_name = "book"
    replicas     = 2

    selector {
      match_labels = { app = "book" }
    }

    template {
      metadata {
        labels = { app = "book" }
      }

      spec {
        service_account_name = kubernetes_service_account_v1.book.metadata[0].name

        # app 노드에서만 구동
        node_selector = { node = "app" }

        toleration {
          key      = "node"
          operator = "Equal"
          value    = "app"
          effect   = "NoSchedule"
        }

        container {
          name              = "book"
          image             = local.image
          image_pull_policy = "Always"

          port {
            container_port = 8080
          }

          env {
            name  = "AWS_REGION"
            value = local.region
          }
          env {
            name  = "TABLE_NAME"
            value = local.table_name
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }
  }

  depends_on = [
    aws_eks_node_group.app,
    aws_eks_pod_identity_association.book,
    null_resource.build_push_book,
  ]
}

# ALB TargetGroupBinding 이 파드 IP 를 찾기 위한 Service
resource "kubernetes_service_v1" "book" {
  metadata {
    name      = "book"
    namespace = kubernetes_namespace_v1.book.metadata[0].name
  }
  spec {
    selector = { app = "book" }
    port {
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}
