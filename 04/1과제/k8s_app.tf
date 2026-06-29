# ═══════════════════════════════════════════════════════════════
# App IAM / Pod Identity  (과제 9.4)
#   - App Pod 의 DynamoDB 접근 (IRSA/Pod Identity, 노드 IAM 미사용)
#   - book-sa(ns=wsc) <-> wsc-book-app-role 매핑
#
# NOTE: Namespace/ServiceAccount/ConfigMap/Deployment/Service/StorageClass 등
#       kubernetes_* 리소스는 2단계(k8s/) 스테이지로 분리되었다.
#       Pod Identity Association 은 namespace/service_account 를 "이름(문자열)" 으로
#       매핑하므로 k8s SA 리소스에 의존하지 않는다. (root 가 먼저 적용되어도 무방)
# ═══════════════════════════════════════════════════════════════

# ── App Pod 의 DynamoDB 접근 (IRSA/Pod Identity, 노드 IAM 미사용) ──
resource "aws_iam_role" "book_app" {
  name = "wsc-book-app-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "book_app" {
  name = "DynamoKms"
  role = aws_iam_role.book_app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:UpdateItem", "dynamodb:DescribeTable"]
        Resource = [aws_dynamodb_table.this.arn, "${aws_dynamodb_table.this.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = [aws_kms_key.main.arn]
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "book" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = "wsc"
  service_account = "book-sa"
  role_arn        = aws_iam_role.book_app.arn
  depends_on      = [aws_eks_addon.pod_identity]
}
