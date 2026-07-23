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

data "aws_caller_identity" "current" {}

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
      {
        Sid      = "ReadInputCsv"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.score.arn}/input/*"
      },
      {
        Sid      = "WriteValidationErrors"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.score.arn}/error/*"
      },
      {
        Sid      = "WriteStudentScores"
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.score.arn
      },
      {
        Sid      = "WriteLambdaLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:ap-southeast-1:*:*"
      }
    ]
  })
}

data "archive_file" "score" {
  type        = "zip"
  source_file = "${path.module}/src/score.py"
  output_path = "${path.module}/score.zip"
}
resource "aws_lambda_function" "score" {
  function_name    = "wsc2026-student-score-function"
  role             = aws_iam_role.lambda.arn
  handler          = "score.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.score.output_path
  source_code_hash = data.archive_file.score.output_base64sha256
  timeout          = 60
  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.score.id
      DDB_TABLE = aws_dynamodb_table.score.name
    }
  }
  depends_on = [aws_iam_role_policy.lambda]
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
  name = "workflow-min"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeScoreProcessor"
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.score.arn
      },
      {
        Sid      = "ReadInputObject"
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.score.arn}/input/*"
      },
      {
        Sid    = "MoveInputObject"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:DeleteObject"]
        Resource = [
          "${aws_s3_bucket.score.arn}/input/*",
          "${aws_s3_bucket.score.arn}/processed/*",
          "${aws_s3_bucket.score.arn}/error/*"
        ]
      }
    ]
  })
}
resource "aws_sfn_state_machine" "score" {
  name     = "wsc2026-student-score-workflow"
  type     = "STANDARD"
  role_arn = aws_iam_role.sfn.arn
  definition = jsonencode({
    Comment = "Validate S3 CSV, process student scores, and move the source file"
    StartAt = "CheckS3File"
    States = {
      CheckS3File = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:s3:headObject"
        Parameters = {
          Bucket  = aws_s3_bucket.score.id
          "Key.$" = "$.key"
        }
        ResultPath = null
        Next       = "ProcessStudentData"
        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "FileNotFound"
        }]
      }
      ProcessStudentData = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.score.function_name
          Payload = {
            "key.$" = "$.key"
          }
        }
        ResultPath = "$.lambda"
        Retry = [{
          ErrorEquals = [
            "Lambda.ServiceException",
            "Lambda.AWSLambdaException",
            "Lambda.SdkClientException",
            "Lambda.TooManyRequestsException",
            "States.TaskFailed"
          ]
          IntervalSeconds = 2
          MaxAttempts     = 3
          BackoffRate     = 2.0
        }]
        Next = "CheckResult"
      }
      CheckResult = {
        Type = "Choice"
        Choices = [{
          Variable      = "$.lambda.Payload.statusCode"
          NumericEquals = 200
          Next          = "MoveToProcessed"
        }]
        Default = "MoveToError"
      }
      MoveToProcessed = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:s3:copyObject"
        Parameters = {
          Bucket         = aws_s3_bucket.score.id
          "CopySource.$" = "States.Format('${aws_s3_bucket.score.id}/{}', $.key)"
          "Key.$"        = "States.Format('processed/{}', States.ArrayGetItem(States.StringSplit($.key, '/'), 1))"
        }
        ResultPath = null
        Next       = "DeleteProcessedSource"
      }
      DeleteProcessedSource = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:s3:deleteObject"
        Parameters = {
          Bucket  = aws_s3_bucket.score.id
          "Key.$" = "$.key"
        }
        ResultPath = null
        End        = true
      }
      MoveToError = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:s3:copyObject"
        Parameters = {
          Bucket         = aws_s3_bucket.score.id
          "CopySource.$" = "States.Format('${aws_s3_bucket.score.id}/{}', $.key)"
          "Key.$"        = "States.Format('error/{}', States.ArrayGetItem(States.StringSplit($.key, '/'), 1))"
        }
        ResultPath = null
        Next       = "DeleteErrorSource"
      }
      DeleteErrorSource = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:s3:deleteObject"
        Parameters = {
          Bucket  = aws_s3_bucket.score.id
          "Key.$" = "$.key"
        }
        ResultPath = null
        Next       = "WorkflowFailed"
      }
      FileNotFound = {
        Type  = "Fail"
        Error = "S3FileNotFound"
        Cause = "The input CSV object does not exist"
      }
      WorkflowFailed = {
        Type  = "Fail"
        Error = "StudentDataProcessingFailed"
        Cause = "The score processor returned a non-200 statusCode"
      }
    }
  })
  depends_on = [aws_iam_role_policy.sfn]
}

# ── S3 ObjectCreated -> Trigger Lambda -> Step Functions ─────────────
resource "aws_iam_role_policy" "lambda_trigger" {
  name = "start-workflow-min"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.score.arn
    }]
  })
}

data "archive_file" "trigger" {
  type        = "zip"
  source_file = "${path.module}/src/trigger.py"
  output_path = "${path.module}/trigger.zip"
}
resource "aws_lambda_function" "trigger" {
  function_name    = "wsc2026-student-score-trigger"
  role             = aws_iam_role.lambda.arn
  handler          = "trigger.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.trigger.output_path
  source_code_hash = data.archive_file.trigger.output_base64sha256
  timeout          = 30
  environment {
    variables = {
      STATE_MACHINE_ARN = aws_sfn_state_machine.score.arn
    }
  }
  depends_on = [
    aws_iam_role_policy.lambda,
    aws_iam_role_policy.lambda_trigger
  ]
}
resource "aws_lambda_permission" "s3_trigger" {
  statement_id   = "AllowS3InvokeStudentScoreTrigger"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.trigger.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.score.arn
  source_account = data.aws_caller_identity.current.account_id
}
resource "aws_s3_bucket_notification" "eb" {
  bucket = aws_s3_bucket.score.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.trigger.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "input/"
    filter_suffix       = ".csv"
  }
  depends_on = [aws_lambda_permission.s3_trigger]
}

# vf test.csv를 최초 한 번 업로드하고 비동기 Workflow 완료까지 확인한다.
resource "terraform_data" "upload_test_csv" {
  triggers_replace = [
    filesha256("${path.module}/test.csv"),
    data.archive_file.score.output_base64sha256,
    data.archive_file.trigger.output_base64sha256,
    sha256(aws_sfn_state_machine.score.definition)
  ]
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      BUCKET = aws_s3_bucket.score.id
      REGION = "ap-southeast-1"
    }
    command = <<-EOT
      set -euo pipefail
      aws s3 cp "${path.module}/test.csv" "s3://$BUCKET/input/test.csv" --region "$REGION" --only-show-errors
      for attempt in $(seq 1 36); do
        if aws s3api head-object --bucket "$BUCKET" --key processed/test.csv --region "$REGION" >/dev/null 2>&1; then
          echo "Workflow completed: s3://$BUCKET/processed/test.csv"
          exit 0
        fi
        sleep 5
      done
      echo "Workflow did not create processed/test.csv within 180 seconds" >&2
      exit 1
    EOT
  }
  depends_on = [aws_s3_bucket_notification.eb]
}

output "bucket" { value = aws_s3_bucket.score.id }
output "state_machine_arn" { value = aws_sfn_state_machine.score.arn }
