# ═══════════════════════════════════════════════════════════════
# book Application — AWS 리소스 (과제 5/8)
#   * Kubernetes 리소스(Namespace/SA/ConfigMap/Deployment/Service/StorageClass)
#     는 ./k8s 스테이지로 이동했다. 여기에는 AWS 리소스만 남긴다.
#   - book Pod 의 DynamoDB 접근 IAM Role + Pod Identity (wskorea26-book-sa)
# 채점 5-3 관련 k8s 리소스는 k8s/main.tf 참조.
# ═══════════════════════════════════════════════════════════════

# book Pod 의 DynamoDB 접근 (Pod Identity)
resource "aws_iam_role" "book_app" {
  name = "wskorea26-book-app-role"
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
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:UpdateItem", "dynamodb:DescribeTable"]
        Resource = [aws_dynamodb_table.this.arn, "${aws_dynamodb_table.this.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = [aws_kms_key.dynamodb.arn]
      }
    ]
  })
}

# SA(wskorea26-book-sa)는 ./k8s 스테이지에서 생성된다.
# Pod Identity 연결은 SA 이름(문자열)만 필요하므로 root 에서 먼저 만들어 둔다.
resource "aws_eks_pod_identity_association" "book" {
  cluster_name    = aws_eks_cluster.this.name
  namespace       = local.namespace
  service_account = "wskorea26-book-sa"
  role_arn        = aws_iam_role.book_app.arn
  depends_on      = [aws_eks_addon.pod_identity]
}
