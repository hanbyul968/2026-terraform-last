# ═══════════════════════════════════════════════════════════════
# Logging  (과제 11 - Fluent Bit)
#   - Fluent Bit DaemonSet -> CloudWatch Logs
#   - 실제 API 요청 로그만 수집(/health 등 제외)
#   - key=value/JSON 파싱하여 method, path, status, duration 구조화
#   - 로그 그룹 CMK(eks-kms) 암호화
# ═══════════════════════════════════════════════════════════════

resource "aws_cloudwatch_log_group" "app" {
  name              = "/wsc2026/app/log"
  retention_in_days = 7
  kms_key_id        = aws_kms_key.eks.arn
  tags              = { Name = "/wsc2026/app/log" }
}

# Fluent Bit -> CloudWatch 쓰기 권한 (Pod Identity)
resource "aws_iam_role" "fluentbit" {
  name = "wsc2026-fluentbit-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "fluentbit" {
  name = "CwLogs"
  role = aws_iam_role.fluentbit.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:CreateLogGroup", "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:DescribeLogGroups"]
        Resource = "${aws_cloudwatch_log_group.app.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = aws_kms_key.eks.arn
      }
    ]
  })
}

resource "kubernetes_service_account_v1" "fluentbit" {
  metadata {
    name      = "fluent-bit"
    namespace = kubernetes_namespace_v1.obs.metadata[0].name
  }
}

resource "aws_eks_pod_identity_association" "fluentbit" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = local.obs_namespace
  service_account = "fluent-bit"
  role_arn        = aws_iam_role.fluentbit.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

resource "helm_release" "fluentbit" {
  name       = "fluent-bit"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  namespace  = kubernetes_namespace_v1.obs.metadata[0].name

  values = [templatefile("${path.module}/k8s/fluentbit-values.yaml.tftpl", {
    log_group = aws_cloudwatch_log_group.app.name
    region    = local.region
    sa_name   = kubernetes_service_account_v1.fluentbit.metadata[0].name
  })]

  depends_on = [
    aws_eks_pod_identity_association.fluentbit,
    aws_eks_node_group.addon,
    aws_eks_node_group.workload,
    helm_release.lb_controller,
  ]
}
