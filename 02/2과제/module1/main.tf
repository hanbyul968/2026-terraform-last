terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
  }
}

# 2-1 Workflow (Student score) — ap-southeast-1
provider "aws" {
  region = "ap-southeast-1"
}

variable "bibunho" {
  description = "선수 비번호 (S3 버킷 접미사)"
  type        = string
}

# ── S3 (input/ processed/ error/) ───────────────────────────────────
resource "aws_s3_bucket" "score" {
  bucket        = "wsc2026-student-score-bucket-${var.bibunho}"
  force_destroy = true
}
resource "aws_s3_object" "input_prefix" {
  bucket = aws_s3_bucket.score.id
  key    = "input/"
}
resource "aws_s3_object" "processed_prefix" {
  bucket = aws_s3_bucket.score.id
  key    = "processed/"
}
resource "aws_s3_object" "error_prefix" {
  bucket = aws_s3_bucket.score.id
  key    = "error/"
}

# ── DynamoDB (PK studentId, SK examDate) ─────────────────────────────
resource "aws_dynamodb_table" "score" {
  name         = "wsc2026-student-score"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "studentId"
  range_key    = "examDate"
  attribute {
    name = "studentId"
    type = "S"
  }
  attribute {
    name = "examDate"
    type = "S"
  }
}

# ── Lambda IAM (least-priv) ──────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "wsc2026-lambda-student-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy" "lambda" {
  name = "score-min"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"], Resource = [aws_s3_bucket.score.arn, "${aws_s3_bucket.score.arn}/*"] },
      { Effect = "Allow", Action = ["dynamodb:PutItem", "dynamodb:BatchWriteItem"], Resource = aws_dynamodb_table.score.arn },
      { Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:*:*:*" }
    ]
  })
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/score.zip"
}
resource "aws_lambda_function" "score" {
  function_name    = "wsc2026-student-score-processor"
  role             = aws_iam_role.lambda.arn
  handler          = "score.lambda_handler"
  runtime          = "python3.14"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 60
  environment { variables = { TABLE_NAME = aws_dynamodb_table.score.name } }
}

# ── Step Functions ───────────────────────────────────────────────────
resource "aws_iam_role" "sfn" {
  name = "wsc2026-stepfunction-student-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "states.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy" "sfn" {
  name = "invoke-min"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["lambda:InvokeFunction"], Resource = aws_lambda_function.score.arn }]
  })
}
resource "aws_sfn_state_machine" "score" {
  name     = "wsc2026-student-score-workflow"
  type     = "STANDARD"
  role_arn = aws_iam_role.sfn.arn
  definition = jsonencode({
    Comment = "Read S3 score CSV -> transform -> DynamoDB"
    StartAt = "ProcessScores"
    States = {
      ProcessScores = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.score.function_name
          "Payload.$"  = "$"
        }
        End = true
      }
    }
  })
}

# S3 -> EventBridge -> Step Functions (input/ 업로드 시 실행)
resource "aws_s3_bucket_notification" "eb" {
  bucket      = aws_s3_bucket.score.id
  eventbridge = true
}
resource "aws_iam_role" "eb" {
  name = "wsc2026-eb-student-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "events.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}
resource "aws_iam_role_policy" "eb" {
  name = "start-exec"
  role = aws_iam_role.eb.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["states:StartExecution"], Resource = aws_sfn_state_machine.score.arn }]
  })
}
resource "aws_cloudwatch_event_rule" "s3" {
  name = "wsc2026-student-score-rule"
  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [aws_s3_bucket.score.id] }
      object = { key = [{ prefix = "input/" }] }
    }
  })
}
resource "aws_cloudwatch_event_target" "sfn" {
  rule     = aws_cloudwatch_event_rule.s3.name
  arn      = aws_sfn_state_machine.score.arn
  role_arn = aws_iam_role.eb.arn
  input_transformer {
    input_paths = {
      bucket = "$.detail.bucket.name"
      key    = "$.detail.object.key"
    }
    input_template = "{\"bucket\": <bucket>, \"key\": <key>}"
  }
}

output "bucket" { value = aws_s3_bucket.score.id }
output "state_machine_arn" { value = aws_sfn_state_machine.score.arn }
