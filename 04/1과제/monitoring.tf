# ═══════════════════════════════════════════════════════════════
# Observability & Monitoring  (과제 11)  + Addon LB (과제 12.2)
#   - Prometheus(node-exporter, kube-state-metrics) + Grafana, monitoring ns
#   - PVC: wsc-prometheus-pvc, wsc-grafana-pvc (wsc-sc, 채점 6-7-D)
#   - Grafana datasource: http://prometheus-server.monitoring.svc.wsc.local/prometheus
#   - Dashboard: wsc-eks-dashboard (6 panels)
#   - Addon LB(public): /grafana, /prometheus  (wsc-addon-lb)
# ═══════════════════════════════════════════════════════════════

# ── 고정 이름 PVC (채점이 이름을 정확히 확인) ──
resource "kubernetes_persistent_volume_claim_v1" "prometheus" {
  metadata {
    name      = "wsc-prometheus-pvc"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.wsc.metadata[0].name
    resources {
      requests = { storage = "10Gi" }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim_v1" "grafana" {
  metadata {
    name      = "wsc-grafana-pvc"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.wsc.metadata[0].name
    resources {
      requests = { storage = "5Gi" }
    }
  }
  wait_until_bound = false
}

# ── Grafana dashboard (wsc-eks-dashboard) ──
resource "kubernetes_config_map_v1" "dashboard" {
  metadata {
    name      = "wsc-eks-dashboard"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = {
    "wsc-eks-dashboard.json" = file("${path.module}/k8s/wsc-eks-dashboard.json")
  }
}

# ── Prometheus ──
resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [templatefile("${path.module}/k8s/prometheus-values.yaml.tftpl", {
    registry = local.registry
    pvc_name = kubernetes_persistent_volume_claim_v1.prometheus.metadata[0].name
  })]

  depends_on = [
    aws_eks_node_group.monitoring,
    kubernetes_storage_class_v1.wsc,
    helm_release.lb_controller,
  ]
}

# ── Grafana ──
resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [templatefile("${path.module}/k8s/grafana-values.yaml.tftpl", {
    registry       = local.registry
    pvc_name       = kubernetes_persistent_volume_claim_v1.grafana.metadata[0].name
    admin_password = var.ssh_password
    ds_url         = "http://prometheus-server.monitoring.svc.${var.cluster_dns_domain}/prometheus"
  })]

  depends_on = [
    helm_release.prometheus,
    kubernetes_config_map_v1.dashboard,
  ]
}

# ── Addon LB (public, ingress 로 생성) : /grafana, /prometheus ──
resource "kubernetes_ingress_v1" "addon" {
  metadata {
    name      = "wsc-addon-ingress"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                  = "alb"
      "alb.ingress.kubernetes.io/scheme"             = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"        = "ip"
      "alb.ingress.kubernetes.io/load-balancer-name" = "wsc-addon-lb"
      "alb.ingress.kubernetes.io/subnets"            = "${aws_subnet.public_a.id},${aws_subnet.public_c.id}"
      "alb.ingress.kubernetes.io/listen-ports"       = "[{\"HTTP\":80}]"
    }
  }
  spec {
    rule {
      http {
        path {
          path      = "/grafana"
          path_type = "Prefix"
          backend {
            service {
              name = "grafana"
              port { number = 80 }
            }
          }
        }
        path {
          path      = "/prometheus"
          path_type = "Prefix"
          backend {
            service {
              name = "prometheus-server"
              port { number = 80 }
            }
          }
        }
      }
    }
  }
  depends_on = [helm_release.grafana, helm_release.prometheus, helm_release.lb_controller]
}
