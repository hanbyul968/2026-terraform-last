# ═══════════════════════════════════════════════════════════════
# Kubernetes - Book App  (과제 8)
#   Namespace: wsc2026 / observability
#   ConfigMap: book-config  (AWS_REGION, TABLE_NAME)  -> 채점 5-3
#   Deployment: wsc2026-book-deploy  (replicas 2, zone 분산, probes)
#   Service: wsc2026-book-svc  (동일 AZ 우선 라우팅)
#   PDB: wsc2026-book-pdb  (minAvailable 1)
#   SA: wsc2026-book-sa + Pod Identity(wsc2026-book-pod-role)
#   Ingress: wsc2026-book-ingress  -> ALB wsc2026-app-alb (internet-facing)
# ═══════════════════════════════════════════════════════════════

resource "kubernetes_namespace_v1" "app" {
  metadata { name = local.app_namespace }
  depends_on = [aws_eks_node_group.workload]
}

resource "kubernetes_namespace_v1" "obs" {
  metadata { name = local.obs_namespace }
  depends_on = [aws_eks_node_group.addon]
}

# ── SA + Pod Identity (DynamoDB PutItem) ──
resource "kubernetes_service_account_v1" "book" {
  metadata {
    name      = local.sa_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
}

resource "aws_eks_pod_identity_association" "book" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = local.app_namespace
  service_account = local.sa_name
  role_arn        = aws_iam_role.book_pod.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

# ── ConfigMap (환경변수, 하드코딩 금지) : 이름 book-config ──
resource "kubernetes_config_map_v1" "book" {
  metadata {
    name      = "book-config"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  data = {
    AWS_REGION = local.region
    TABLE_NAME = local.table_name
  }
}

# ── Deployment ──
resource "kubernetes_deployment_v1" "book" {
  metadata {
    name      = local.deploy_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    labels    = { app = "wsc2026-book" }
  }
  spec {
    replicas = 2
    selector {
      match_labels = { app = "wsc2026-book" }
    }
    template {
      metadata {
        labels = { app = "wsc2026-book" }
      }
      spec {
        service_account_name = local.sa_name
        node_selector        = { "wsc2026/node" = "application" }

        # AZ 간 균등 분산 (채점 5-2: topology.kubernetes.io/zone)
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "DoNotSchedule"
          label_selector {
            match_labels = { app = "wsc2026-book" }
          }
        }

        container {
          name  = "book"
          image = local.image_url
          port {
            container_port = 8080
          }
          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.book.metadata[0].name
            }
          }
          resources {
            requests = { cpu = "256m", memory = "512Mi" }
            limits   = { cpu = "256m", memory = "512Mi" }
          }
          startup_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            failure_threshold = 30
            period_seconds    = 5
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            period_seconds = 10
          }
        }
      }
    }
  }
  depends_on = [aws_eks_pod_identity_association.book, null_resource.build_push_book]
}

# ── Service (동일 AZ 우선 라우팅으로 Cross-AZ 비용 절감) ──
resource "kubernetes_service_v1" "book" {
  metadata {
    name      = local.service_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    annotations = {
      "service.kubernetes.io/topology-mode" = "Auto"
    }
  }
  spec {
    selector = { app = "wsc2026-book" }
    port {
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}

# ── PDB (최소 1 가용) ──
resource "kubernetes_pod_disruption_budget_v1" "book" {
  metadata {
    name      = local.pdb_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }
  spec {
    min_available = 1
    selector {
      match_labels = { app = "wsc2026-book" }
    }
  }
}

# ── Ingress -> ALB(internet-facing) wsc2026-app-alb ──
resource "kubernetes_ingress_v1" "book" {
  metadata {
    name      = local.ingress_name
    namespace = kubernetes_namespace_v1.app.metadata[0].name
    annotations = {
      "alb.ingress.kubernetes.io/scheme"                              = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"                         = "ip"
      "alb.ingress.kubernetes.io/load-balancer-name"                  = local.alb_name
      "alb.ingress.kubernetes.io/subnets"                             = "${aws_subnet.hub_a.id},${aws_subnet.hub_b.id}"
      "alb.ingress.kubernetes.io/security-groups"                     = aws_security_group.alb.id
      "alb.ingress.kubernetes.io/manage-backend-security-group-rules" = "true"
      "alb.ingress.kubernetes.io/listen-ports"                        = "[{\"HTTP\":80}]"
      "alb.ingress.kubernetes.io/healthcheck-path"                    = "/health"
      "alb.ingress.kubernetes.io/healthcheck-port"                    = "8080"
      # 잘못된 경로는 403 (채점 12 / CDN 외 직접 경로)
      "alb.ingress.kubernetes.io/actions.deny-403" = jsonencode({
        type = "fixed-response"
        fixedResponseConfig = {
          contentType = "application/json"
          statusCode  = "403"
          messageBody = "Forbidden"
        }
      })
    }
  }
  spec {
    ingress_class_name = "alb"
    rule {
      http {
        # 실제 경로
        path {
          path      = "/v1/book"
          path_type = "Prefix"
          backend {
            service {
              name = local.service_name
              port { number = 8080 }
            }
          }
        }
        # 그 외 모든 경로 -> 403
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "deny-403"
              port { name = "use-annotation" }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.lb_controller, kubernetes_service_v1.book]
}

# ═══════════════════════════════════════════════════════════════
# AWS Load Balancer Controller
# ═══════════════════════════════════════════════════════════════
resource "aws_iam_policy" "lb_controller" {
  name   = "wsc2026-AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/files/lb-controller-policy.json")
}

resource "aws_iam_role" "lb_controller" {
  name = "wsc2026-lb-controller-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = aws_eks_cluster.this.name
  }
  set {
    name  = "region"
    value = local.region
  }
  set {
    name  = "vpcId"
    value = aws_vpc.this.id
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "nodeSelector.wsc2026/node"
    value = "addon"
  }

  depends_on = [
    aws_eks_node_group.addon,
    aws_eks_pod_identity_association.lb_controller,
    aws_eks_addon.coredns,
  ]
}
