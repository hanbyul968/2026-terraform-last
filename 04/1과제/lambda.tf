# ═══════════════════════════════════════════════════════════════
# Lambda  (과제 15)
#   - Name: wsc-get-table-function / Runtime python3.14
#   - Private Subnet 에서 실행 (채점 4-1-B: subnet MapPublicIpOnLaunch False)
#   - wsc-app-lb 의 Target 으로 등록 (GET /v1/book)
#   - DynamoDB 없을 시 404 {"msg":"Item not found"}
# ═══════════════════════════════════════════════════════════════

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/files/lambda_function.py"
  output_path = "${path.module}/files/lambda_function.zip"
}

resource "aws_iam_role" "lambda" {
  name = "wsc-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_dynamo" {
  name = "DynamoReadKms"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Query", "dynamodb:GetItem", "dynamodb:Scan", "dynamodb:DescribeTable"]
        Resource = [aws_dynamodb_table.this.arn, "${aws_dynamodb_table.this.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey*"]
        Resource = [aws_kms_key.main.arn]
      }
    ]
  })
}

resource "aws_security_group" "lambda" {
  name        = "wsc-lambda-sg"
  description = "Lambda ENI SG"
  vpc_id      = aws_vpc.this.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "wsc-lambda-sg" }
}

resource "aws_lambda_function" "get_table" {
  function_name    = "wsc-get-table-function"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.14"
  handler          = "lambda_function.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 15
  memory_size      = 128

  environment {
    variables = {
      TABLE_NAME      = local.table_name
      AWS_REGION_NAME = local.region
    }
  }

  vpc_config {
    subnet_ids         = [aws_subnet.private_a.id, aws_subnet.private_c.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_vpc]
}

# ALB(Lambda target) 호출 권한
resource "aws_lambda_permission" "alb" {
  statement_id  = "AllowALBInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_table.function_name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.lambda.arn
}
