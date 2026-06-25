# ═══════════════════════════════════════════════════════════════
# Monitoring  (과제 12)
#   - monitoring ns (addon 노드그룹에서 동작)
#   - Prometheus(클러스터/컨테이너 메트릭) + Grafana 시각화
#   - Grafana: 인터넷 LB(wskorea26-grafana-alb) HTTP 80, admin/wsk2026!
#   - Dashboard: wskorea26-monitoring (uid wskorea26) — 5개 지표 패널
# 채점 10-1: Grafana 로그인 후 대시보드 지표 확인(수동)
# ═══════════════════════════════════════════════════════════════

resource "kubernetes_namespace_v1" "monitoring" {
  metadata { name = "monitoring" }
  depends_on = [aws_eks_node_group.addon]
}

resource "kubernetes_persistent_volume_claim_v1" "prometheus" {
  metadata {
    name      = "wskorea26-prometheus-pvc"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ebs.metadata[0].name
    resources {
      requests = { storage = "10Gi" }
    }
  }
  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim_v1" "grafana" {
  metadata {
    name      = "wskorea26-grafana-pvc"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = kubernetes_storage_class_v1.ebs.metadata[0].name
    resources {
      requests = { storage = "5Gi" }
    }
  }
  wait_until_bound = false
}

# Grafana 대시보드 (sidecar 자동 로드)
resource "kubernetes_config_map_v1" "dashboard" {
  metadata {
    name      = "wskorea26-dashboard"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = {
    "wskorea26-dashboard.json" = file("${path.module}/k8s/wskorea26-dashboard.json")
  }
}

resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [templatefile("${path.module}/k8s/prometheus-values.yaml.tftpl", {
    pvc_name = kubernetes_persistent_volume_claim_v1.prometheus.metadata[0].name
  })]

  depends_on = [
    aws_eks_node_group.addon,
    kubernetes_storage_class_v1.ebs,
    helm_release.lb_controller,
  ]
}

resource "helm_release" "grafana" {
  name       = "grafana"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [templatefile("${path.module}/k8s/grafana-values.yaml.tftpl", {
    pvc_name       = kubernetes_persistent_volume_claim_v1.grafana.metadata[0].name
    admin_user     = var.grafana_admin_user
    admin_password = var.grafana_admin_password
    ds_url         = "http://prometheus-server.monitoring.svc.cluster.local"
  })]

  depends_on = [
    helm_release.prometheus,
    kubernetes_config_map_v1.dashboard,
    helm_release.lb_controller,
  ]
}
