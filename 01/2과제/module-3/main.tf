terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.80" }
    archive = { source = "hashicorp/archive", version = ">= 2.0" }
  }
}

provider "aws" { region = "us-east-1" }

data "aws_caller_identity" "current" {}

# DynamoDB
resource "aws_dynamodb_table" "target" {
  name         = "wsc2026-target-db"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

# S3
resource "aws_s3_bucket" "inbound" {
  bucket        = "wsc2026-wf-inbound-bucket"
  force_destroy = true
}

resource "aws_s3_bucket_notification" "eb" {
  bucket      = aws_s3_bucket.inbound.id
  eventbridge = true
}

# Lambda IAM
resource "aws_iam_role" "transform" {
  name = "wsc2026-transform-lambda-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "transform" {
  name = "policy"
  role = aws_iam_role.transform.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:ListBucket"], Resource = [aws_s3_bucket.inbound.arn, "${aws_s3_bucket.inbound.arn}/*"] },
      { Effect = "Allow", Action = ["logs:*"], Resource = "*" }
    ]
  })
}

# Lambda
data "archive_file" "transform" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/transform.zip"
}

resource "aws_lambda_function" "transform" {
  function_name    = "wsc2026-transform-lambda"
  role             = aws_iam_role.transform.arn
  handler          = "transform.lambda_handler"
  runtime          = "python3.14"
  filename         = data.archive_file.transform.output_path
  source_code_hash = data.archive_file.transform.output_base64sha256
  timeout          = 30
}

# Step Functions IAM
resource "aws_iam_role" "sfn" {
  name = "wsc2026-sfn-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "states.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  name = "policy"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = aws_lambda_function.transform.arn },
      { Effect = "Allow", Action = ["dynamodb:PutItem"], Resource = aws_dynamodb_table.target.arn }
    ]
  })
}

# Step Functions State Machine
resource "aws_sfn_state_machine" "wf" {
  name     = "wsc2026-wf-statemachine"
  role_arn = aws_iam_role.sfn.arn
  definition = jsonencode({
    Comment = "S3 inbound data processing workflow"
    StartAt = "TransformData"
    States = {
      TransformData = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.transform.function_name
          "Payload.$"  = "$"
        }
        ResultSelector = { "transformed.$" = "$.Payload.body" }
        ResultPath     = "$.result"
        Next           = "SaveToDynamoDB"
        Catch = [
          { ErrorEquals = ["ValidationError"], Next = "HandleError" },
          { ErrorEquals = ["TransformError"], Next = "HandleError" }
        ]
      }
      SaveToDynamoDB = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:putItem"
        Parameters = {
          TableName = aws_dynamodb_table.target.name
          Item = {
            "id"           = { "S.$" = "$.result.transformed.id" }
            "data"         = { "S.$" = "$.result.transformed.data" }
            "status"       = { "S.$" = "$.result.transformed.status" }
            "processed_at" = { "S.$" = "$.result.transformed.processed_at" }
          }
        }
        End = true
      }
      HandleError = {
        Type  = "Fail"
        Error = "WorkflowError"
        Cause = "Data transform or validation failed"
      }
    }
  })
}

# EventBridge IAM
resource "aws_iam_role" "eb" {
  name = "wsc2026-eb-sfn-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "events.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "eb" {
  name = "policy"
  role = aws_iam_role.eb.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "states:StartExecution", Resource = aws_sfn_state_machine.wf.arn }]
  })
}

# EventBridge Rule
resource "aws_cloudwatch_event_rule" "s3" {
  name = "wsc2026-s3-trigger-rule"
  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail      = { bucket = { name = ["wsc2026-wf-inbound-bucket"] } }
  })
}

resource "aws_cloudwatch_event_target" "sfn" {
  rule     = aws_cloudwatch_event_rule.s3.name
  arn      = aws_sfn_state_machine.wf.arn
  role_arn = aws_iam_role.eb.arn
}


