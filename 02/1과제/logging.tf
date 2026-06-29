# ═══════════════════════════════════════════════════════════════
# Logging — AWS 리소스 (과제 12: Pod 로그 -> CloudWatch Logs)
#   * Kubernetes/Helm 리소스(logging Namespace/SA, aws-for-fluent-bit helm)
#     는 ./k8s 스테이지로 이동했다. 여기에는 AWS 리소스만 남긴다.
#   - CloudWatch Log Group /wskorea26/pod/log (KMS wskorea26-s3-key 암호화)
#   - Fluent Bit IAM Role + Pod Identity (logging/fluent-bit SA)
# ═══════════════════════════════════════════════════════════════

resource "aws_cloudwatch_log_group" "pod" {
  name              = "/wskorea26/pod/log"
  retention_in_days = 7
  kms_key_id        = aws_kms_key.s3.arn
  tags              = { Name = "/wskorea26/pod/log" }
}

resource "aws_iam_role" "fluentbit" {
  name = "wskorea26-fluentbit-role"
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
        Resource = aws_kms_key.s3.arn
      }
    ]
  })
}

# SA(fluent-bit)는 ./k8s 스테이지에서 생성된다.
# Pod Identity 연결은 SA 이름(문자열)만 필요하므로 root 에서 먼저 만들어 둔다.
resource "aws_eks_pod_identity_association" "fluentbit" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "logging"
  service_account = "fluent-bit"
  role_arn        = aws_iam_role.fluentbit.arn
  depends_on      = [aws_eks_addon.pod_identity]
}
