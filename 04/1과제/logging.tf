# ═══════════════════════════════════════════════════════════════
# Logging  (과제 10)
#   - Fluent Bit DaemonSet (name: fluent-bit) in logging ns
#   - app 로그 -> CloudWatch /wsc/pod/log  (stream /wsc/app/log)
#   - /health 는 로그에서 제외 (채점 12-1-B)
#   - Log Group KMS(CMK) 암호화 (채점 12-1-A)
# ═══════════════════════════════════════════════════════════════

resource "aws_cloudwatch_log_group" "pod" {
  name              = "/wsc/pod/log"
  retention_in_days = 7
  kms_key_id        = aws_kms_key.main.arn
  tags              = { Name = "/wsc/pod/log" }
}

# Fluent Bit 가 CloudWatch 에 쓰도록 Pod Identity
resource "aws_iam_role" "fluentbit" {
  name = "wsc-fluentbit-role"
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
        Resource = "${aws_cloudwatch_log_group.pod.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey*", "kms:Decrypt"]
        Resource = aws_kms_key.main.arn
      }
    ]
  })
}

resource "kubernetes_service_account_v1" "fluentbit" {
  metadata {
    name      = "fluent-bit"
    namespace = kubernetes_namespace_v1.logging.metadata[0].name
  }
}

resource "aws_eks_pod_identity_association" "fluentbit" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "logging"
  service_account = "fluent-bit"
  role_arn        = aws_iam_role.fluentbit.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

# Fluent Bit Helm. 노드는 인터넷이 없으므로 이미지를 ECR pull-through 로 가져온다.
resource "helm_release" "fluentbit" {
  name       = "fluent-bit"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  namespace  = kubernetes_namespace_v1.logging.metadata[0].name

  values = [templatefile("${path.module}/k8s/fluentbit-values.yaml.tftpl", {
    log_group  = aws_cloudwatch_log_group.pod.name
    log_stream = "/wsc/app/log"
    region     = local.region
    registry   = local.registry
    sa_name    = kubernetes_service_account_v1.fluentbit.metadata[0].name
  })]

  depends_on = [
    aws_eks_pod_identity_association.fluentbit,
    aws_eks_node_group.addon,
    aws_eks_node_group.app,
    helm_release.lb_controller,
  ]
}
