terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

# 4-4 REST API Implement — us-east-1
provider "aws" {
  region = "us-east-1"
}

# ── DynamoDB (Query-only, PK name + SK age) ──────────────────────────
resource "aws_dynamodb_table" "rest" {
  name         = "wsc-rest-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "name"
  range_key    = "age"
  attribute {
    name = "name"
    type = "S"
  }
  attribute {
    name = "age"
    type = "S"
  }
}

# ── Lambda ───────────────────────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "wsc-rest-function-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "ddb-min"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["dynamodb:PutItem", "dynamodb:Query", "dynamodb:GetItem"], Resource = aws_dynamodb_table.rest.arn },
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:*:*:*" }
    ]
  })
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/function.zip"
}

resource "aws_lambda_function" "rest" {
  function_name    = "wsc-rest-function"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.14"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 30
  environment { variables = { TABLE_NAME = aws_dynamodb_table.rest.name } }
}

# ── API Gateway (REST) ───────────────────────────────────────────────
resource "aws_api_gateway_rest_api" "api" {
  name = "wsc-rest-api"
}

resource "aws_api_gateway_resource" "v1" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "v1"
}
resource "aws_api_gateway_resource" "user" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.v1.id
  path_part   = "user"
}
resource "aws_api_gateway_resource" "healthcheck" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.v1.id
  path_part   = "healthcheck"
}

# request validators
resource "aws_api_gateway_request_validator" "params" {
  name                        = "validate-params"
  rest_api_id                 = aws_api_gateway_rest_api.api.id
  validate_request_parameters = true
  validate_request_body       = false
}
resource "aws_api_gateway_request_validator" "body" {
  name                        = "validate-body"
  rest_api_id                 = aws_api_gateway_rest_api.api.id
  validate_request_parameters = false
  validate_request_body       = true
}

# POST /v1/user (API key required, body validation)
resource "aws_api_gateway_method" "user_post" {
  rest_api_id          = aws_api_gateway_rest_api.api.id
  resource_id          = aws_api_gateway_resource.user.id
  http_method          = "POST"
  authorization        = "NONE"
  api_key_required     = true
  request_validator_id = aws_api_gateway_request_validator.body.id
}
resource "aws_api_gateway_integration" "user_post" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.user.id
  http_method             = aws_api_gateway_method.user_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.rest.invoke_arn
}

# GET /v1/user (API key required, query params name+age required)
resource "aws_api_gateway_method" "user_get" {
  rest_api_id          = aws_api_gateway_rest_api.api.id
  resource_id          = aws_api_gateway_resource.user.id
  http_method          = "GET"
  authorization        = "NONE"
  api_key_required     = true
  request_validator_id = aws_api_gateway_request_validator.params.id
  request_parameters = {
    "method.request.querystring.name" = true
    "method.request.querystring.age"  = true
  }
}
resource "aws_api_gateway_integration" "user_get" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.user.id
  http_method             = aws_api_gateway_method.user_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.rest.invoke_arn
}

# GET /v1/healthcheck (MOCK -> {"status":"ok"})
resource "aws_api_gateway_method" "hc_get" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.healthcheck.id
  http_method   = "GET"
  authorization = "NONE"
}
resource "aws_api_gateway_integration" "hc_get" {
  rest_api_id       = aws_api_gateway_rest_api.api.id
  resource_id       = aws_api_gateway_resource.healthcheck.id
  http_method       = aws_api_gateway_method.hc_get.http_method
  type              = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}
resource "aws_api_gateway_method_response" "hc_200" {
  rest_api_id     = aws_api_gateway_rest_api.api.id
  resource_id     = aws_api_gateway_resource.healthcheck.id
  http_method     = aws_api_gateway_method.hc_get.http_method
  status_code     = "200"
  response_models = { "application/json" = "Empty" }
}
resource "aws_api_gateway_integration_response" "hc_200" {
  rest_api_id        = aws_api_gateway_rest_api.api.id
  resource_id        = aws_api_gateway_resource.healthcheck.id
  http_method        = aws_api_gateway_method.hc_get.http_method
  status_code        = aws_api_gateway_method_response.hc_200.status_code
  response_templates = { "application/json" = "{\"status\": \"ok\"}" }
  depends_on         = [aws_api_gateway_integration.hc_get]
}

resource "aws_lambda_permission" "apigw" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rest.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

# Deployment + stage prod
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  depends_on = [
    aws_api_gateway_integration.user_post,
    aws_api_gateway_integration.user_get,
    aws_api_gateway_integration.hc_get,
    aws_api_gateway_integration_response.hc_200,
  ]
  triggers = { redeploy = sha1(jsonencode([
    aws_api_gateway_resource.user.id, aws_api_gateway_resource.healthcheck.id,
    aws_api_gateway_method.user_post.id, aws_api_gateway_method.user_get.id, aws_api_gateway_method.hc_get.id
  ])) }
  lifecycle { create_before_destroy = true }
}
resource "aws_api_gateway_stage" "prod" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = "prod"
}

# API key + usage plan
resource "aws_api_gateway_api_key" "key" {
  name = "wsc-rest-api-key"
}
resource "aws_api_gateway_usage_plan" "plan" {
  name = "wsc-rest-usage-plan"
  api_stages {
    api_id = aws_api_gateway_rest_api.api.id
    stage  = aws_api_gateway_stage.prod.stage_name
  }
}
resource "aws_api_gateway_usage_plan_key" "key" {
  key_id        = aws_api_gateway_api_key.key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.plan.id
}

output "invoke_url" { value = aws_api_gateway_stage.prod.invoke_url }
output "api_key_id" { value = aws_api_gateway_api_key.key.id }
