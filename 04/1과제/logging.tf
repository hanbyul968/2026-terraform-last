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

resource "aws_eks_pod_identity_association" "fluentbit" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "logging"
  service_account = "fluent-bit"
  role_arn        = aws_iam_role.fluentbit.arn
  depends_on      = [aws_eks_addon.pod_identity]
}

# NOTE: fluent-bit ServiceAccount 와 aws-for-fluent-bit Helm 차트는
#       2단계(k8s/) 스테이지(k8s/main.tf)로 분리되었다.
#       Pod Identity Association 은 namespace/service_account 를 이름(문자열)으로
#       매핑하므로 여기(root)에 남아 있어도 k8s SA 리소스에 의존하지 않는다.
