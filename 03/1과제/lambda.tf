# ═══════════════════════════════════════════════════════════════
# Lambda  (과제 10)
#   - Name: wsc2026-book-get-function / Runtime python3.12
#   - GET /v1/book?booking_id=...  -> DynamoDB GSI(booking_id) 조회
#   - Function URL 을 CloudFront 의 별도 Origin 으로 연결
#   - 코드/환경변수(TABLE_NAME) 를 CMK(wsc2026-function-kms) 로 암호화
#       (env 는 전송 중/저장 중 모두 CMK 암호화)
#   - IAM 은 최소 권한(wsc2026-book-function-role/policy, Query 만)
#
# 채점 7-1: Runtime python3.12, TABLE_NAME 이 KMS 암호문으로 출력
# 채점 7-2: role wsc2026-book-function-role / policy wsc2026-book-function-policy
# ═══════════════════════════════════════════════════════════════

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/files/lambda_function.py"
  output_path = "${path.module}/files/lambda_function.zip"
}

resource "aws_lambda_function" "book_get" {
  function_name    = local.lambda_name
  role             = aws_iam_role.book_function.arn
  runtime          = "python3.12"
  handler          = "lambda_function.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 15
  memory_size      = 128

  # 환경변수 + 코드 CMK 암호화
  kms_key_arn = local.kms_function_arn

  environment {
    variables = {
      TABLE_NAME = local.table_name
      INDEX_NAME = "booking_id-index"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.book_function_basic,
    aws_iam_role_policy_attachment.book_function,
  ]
}

# ── Function URL (CloudFront Origin 용) ──
resource "aws_lambda_function_url" "book_get" {
  function_name      = aws_lambda_function.book_get.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "function_url" {
  statement_id           = "AllowFunctionUrlPublic"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.book_get.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}
