# ═══════════════════════════════════════════════════════════════
# Observability — AWS 레이어  (과제 11)
#   kube-prometheus-stack(helm) 과 Grafana dashboard(ConfigMap) 는
#   ./k8s 스테이지로 이동했다. 이 파일에는 Grafana 가 CloudWatch 를 읽기 위한
#   IAM / Pod Identity 만 남긴다.
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
