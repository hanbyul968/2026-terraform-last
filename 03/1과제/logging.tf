# ═══════════════════════════════════════════════════════════════
# Logging — AWS 레이어  (과제 11 - Fluent Bit)
#   Fluent Bit DaemonSet(helm) 와 SA 는 ./k8s 스테이지로 이동했다.
#   이 파일에는 CloudWatch 로그 그룹과 Fluent Bit 의 IAM / Pod Identity 만 남긴다.
#   - 로그 그룹 CMK(eks-kms) 암호화
# ═══════════════════════════════════════════════════════════════

resource "aws_cloudwatch_log_group" "app" {
  name              = "/wsc2026/app/log"
  retention_in_days = 7
  kms_key_id        = local.kms_eks_arn
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
        Resource = local.kms_eks_arn
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "fluentbit" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = local.obs_namespace
  service_account = "fluent-bit"
  role_arn        = aws_iam_role.fluentbit.arn
  depends_on      = [aws_eks_addon.pod_identity]
}
