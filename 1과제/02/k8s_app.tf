# ═══════════════════════════════════════════════════════════════
# book Application — AWS 리소스 (과제 5/8)
#   * Kubernetes 리소스(Namespace/SA/ConfigMap/Deployment/Service/StorageClass)
#     는 ./k8s 스테이지로 이동했다. 여기에는 AWS 리소스만 남긴다.
#   - book Pod 의 DynamoDB 접근 IAM Role + Pod Identity (wskorea26-book-sa)
# 채점 5-3 관련 k8s 리소스는 k8s/main.tf 참조.
# ═══════════════════════════════════════════════════════════════

# book Pod 의 DynamoDB 접근 (IRSA / OIDC)
resource "aws_iam_role" "book_app" {
  name = "wskorea26-book-app-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:${local.namespace}:wskorea26-book-sa"
          "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
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

# SA(wskorea26-book-sa)는 ./k8s 스테이지에서 생성되며, 그 SA 에 이 역할 ARN 을
# eks.amazonaws.com/role-arn 어노테이션으로 붙여 IRSA 로 자격증명을 받는다(agent 불필요).
