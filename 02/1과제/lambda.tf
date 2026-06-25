# ═══════════════════════════════════════════════════════════════
# Lambda  (과제 9)
#   - Name: wskorea26-book-lambda / Runtime python3.14
#   - GET /reserv-query?concert_name=...  (ALB 통해 호출, ALB 포맷)
#   - DynamoDB GSI 로 concert_name 조회, 최신순 정렬
#   - 최소 권한: 대상 테이블 Query + dynamodb 키 Decrypt 만
#   - 연결 값(TABLE_NAME 등)은 환경변수 (하드코딩 금지, Reference03)
# 채점 6-1: FunctionName / python3.14 / Environment.Variables.TABLE_NAME
# ═══════════════════════════════════════════════════════════════

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/files/lambda_function.py"
  output_path = "${path.module}/files/lambda_function.zip"
}

resource "aws_iam_role" "lambda" {
  name = "wskorea26-book-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# 최소 권한: 대상 테이블/인덱스 Query 조회 + dynamodb CMK Decrypt
resource "aws_iam_role_policy" "lambda_dynamo" {
  name = "DynamoQueryKms"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Query", "dynamodb:GetItem"]
        Resource = [aws_dynamodb_table.this.arn, "${aws_dynamodb_table.this.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = [aws_kms_key.dynamodb.arn]
      }
    ]
  })
}

resource "aws_lambda_function" "book" {
  function_name    = "wskorea26-book-lambda"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.14"
  handler          = "lambda_function.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 15
  memory_size      = 128

  environment {
    variables = {
      TABLE_NAME = local.table_name
      GSI_NAME   = local.gsi_name
    }
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_basic]
}

# ALB(Lambda target) 호출 권한
resource "aws_lambda_permission" "alb" {
  statement_id  = "AllowALBInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.book.function_name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.lambda.arn
}
