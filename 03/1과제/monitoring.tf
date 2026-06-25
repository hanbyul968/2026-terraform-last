# ═══════════════════════════════════════════════════════════════
# Observability  (과제 11)
#   - kube-prometheus-stack : Prometheus + Alertmanager + Grafana
#     + node-exporter(DaemonSet) + kube-state-metrics
#   - 데이터 보존 7일 / Addon 노드에서 운영
#   - Alert 규칙 5종 (Reference02)
#   - Grafana: admin/Skills$#$@! , LB 로 외부 노출,
#     datasource = Prometheus + Alertmanager + CloudWatch
#   - Dashboard: wsc2026-grafana-dashboard (임계치 색상)
# ═══════════════════════════════════════════════════════════════

# Grafana 가 CloudWatch(Logs/Metrics) 를 읽기 위한 Pod Identity
resource "aws_iam_role" "grafana" {
  name = "wsc2026-grafana-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "grafana_cw" {
  name = "GrafanaCloudWatch"
  role = aws_iam_role.grafana.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "cloudwatch:DescribeAlarmsForMetric", "cloudwatch:DescribeAlarmHistory",
        "cloudwatch:DescribeAlarms", "cloudwatch:ListMetrics",
        "cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:GetInsightRuleReport",
        "logs:DescribeLogGroups", "logs:GetLogGroupFields", "logs:StartQuery", "logs:StopQuery",
        "logs:GetQueryResults", "logs:GetLogEvents", "logs:FilterLogEvents", "logs:DescribeLogStreams",
        "tag:GetResources", "ec2:DescribeRegions"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "grafana" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = local.obs_namespace
  service_account = "grafana-sa"
  role_arn        = aws_iam_role.grafana.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

# Grafana 대시보드 (sidecar 자동 로드)
resource "kubernetes_config_map_v1" "dashboard" {
  metadata {
    name      = local.dashboard_name
    namespace = kubernetes_namespace_v1.obs.metadata[0].name
    labels    = { grafana_dashboard = "1" }
  }
  data = {
    "wsc2026-grafana-dashboard.json" = file("${path.module}/k8s/wsc-eks-dashboard.json")
  }
}

resource "helm_release" "kps" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace_v1.obs.metadata[0].name

  values = [templatefile("${path.module}/k8s/kps-values.yaml.tftpl", {
    admin_password = var.grafana_admin_password
    region         = local.region
    log_group      = aws_cloudwatch_log_group.app.name
    dashboard_name = local.dashboard_name
  })]

  timeout = 900

  depends_on = [
    aws_eks_node_group.addon,
    aws_eks_pod_identity_association.grafana,
    aws_eks_addon.ebs_csi,
    helm_release.lb_controller,
    kubernetes_config_map_v1.dashboard,
  ]
}
