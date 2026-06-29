terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-1"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# DynamoDB Table
resource "aws_dynamodb_table" "main" {
  name                        = "wsc2026-worldschool-table"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "admission_year"
  range_key                   = "student_name"
  deletion_protection_enabled = true

  attribute {
    name = "admission_year"
    type = "N"
  }

  attribute {
    name = "student_name"
    type = "S"
  }
}

# Lambda IAM Role
resource "aws_iam_role" "lambda" {
  name = "wsc2026-worldschool-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "wsc2026-worldschool-lambda-policy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Scan"]
        Resource = aws_dynamodb_table.main.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
      }
    ]
  })
}

# Lambda Layer
resource "null_resource" "layer_build" {
  # apply 가 Linux Bastion 에서 수행되므로 bash 로 변환 (기존 PowerShell 버전 대체).
  # nested heredoc 없이 printf 로 .env 를 인라인 생성 → lambda.py 의 os.getenv("tableName") 와 일치.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      mkdir -p "${path.module}/layer/python"
      pip3 install python-dotenv -t "${path.module}/layer/python" --quiet
      printf 'tableName=wsc2026-worldschool-table' > "${path.module}/layer/python/.env"
    EOT
  }

  triggers = {
    always_run = timestamp()
  }
}

data "archive_file" "layer" {
  type        = "zip"
  source_dir  = "${path.module}/layer"
  output_path = "${path.module}/layer.zip"
  depends_on  = [null_resource.layer_build]
}

resource "aws_lambda_layer_version" "env_layer" {
  filename            = data.archive_file.layer.output_path
  layer_name          = "wsc2026-worldschool-env-layer"
  compatible_runtimes = ["python3.12", "python3.13"]
  source_code_hash    = data.archive_file.layer.output_base64sha256
}

# Lambda Function
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda.py"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "main" {
  function_name    = "wsc2026-worldschool-management"
  role             = aws_iam_role.lambda.arn
  handler          = "lambda.lambda_handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  layers           = [aws_lambda_layer_version.env_layer.arn]
}

# API Gateway
resource "aws_api_gateway_rest_api" "main" {
  name = "wsc2026-worldschool-api"
}

resource "aws_api_gateway_method" "any" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_rest_api.main.root_resource_id
  http_method   = "ANY"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_rest_api.main.root_resource_id
  http_method             = aws_api_gateway_method.any.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.main.invoke_arn
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.main.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  depends_on  = [aws_api_gateway_integration.lambda]
}

resource "aws_api_gateway_stage" "main" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = "wsc2026-worldschool-api-stage"
}
