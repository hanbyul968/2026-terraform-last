# ═══════════════════════════════════════════════════════════════
# 애플리케이션/람다 IAM  (최소 권한)
#
# 채점 5-5 (Pod Identity Role): 부착된 관리형 정책 Action 에
#   dynamodb:PutItem 이 있고, '*' 가 하나도 없어야 PASS.
# 채점 7-2 (Lambda IAM): function-role 의 비-Basic 정책 Action 에
#   dynamodb:Query 가 있고, '*' 가 하나도 없어야 PASS.
#   => 두 정책 모두 Action 에 와일드카드(*)를 절대 쓰지 않는다.
# ═══════════════════════════════════════════════════════════════

# ── EKS Pod (book 앱) Role : DynamoDB PutItem 만 ──────────────
resource "aws_iam_role" "book_pod" {
  name = local.pod_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_policy" "book_pod" {
  name = "wsc2026-book-pod-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DynamoPut"
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem"]
      Resource = aws_dynamodb_table.this.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "book_pod" {
  role       = aws_iam_role.book_pod.name
  policy_arn = aws_iam_policy.book_pod.arn
}

# ── Lambda(GET) Role : DynamoDB Query 만 ──────────────────────
resource "aws_iam_role" "book_function" {
  name = local.func_role_name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# CloudWatch 로그 권한은 관리형(AWSLambdaBasicExecutionRole) 대신
# wsc2026-book-function-policy 인라인에 포함(위 "Logs" Statement) → 7-2 예상출력과 동일하게 정책 1개만 부착.

resource "aws_iam_policy" "book_function" {
  name = local.func_policy
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DynamoQuery"
        Effect   = "Allow"
        Action   = ["dynamodb:Query"]
        Resource = [aws_dynamodb_table.this.arn, "${aws_dynamodb_table.this.arn}/index/booking_id-index"]
      },
      {
        Sid      = "DecryptTableName"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = local.kms_function_arn
      },
      {
        # CloudWatch 로그 권한(관리형 AWSLambdaBasicExecutionRole 대신 인라인).
        # 7-2 예상출력이 정책 1개(wsc2026-book-function-policy)만 나오도록 함.
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:${local.partition}:logs:*:*:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "book_function" {
  role       = aws_iam_role.book_function.name
  policy_arn = aws_iam_policy.book_function.arn
}
