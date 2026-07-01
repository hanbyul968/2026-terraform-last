# =============================================================================
# Module 3. Workflow (S3 + Lambda + DynamoDB + Step Functions)  | Region: ap-southeast-1
#  - 버킷 workflow-input-<비번호> (data.csv 업로드, tag Module=Workflow)
#  - DynamoDB workflow-output : PK id(S), On-Demand
#  - Lambda workflow-transform (py3.12, timeout 60, env TABLE_NAME)
#  - Step Functions workflow-state-machine (STANDARD)
#  - 실행하여 workflow-output에 데이터 저장
# =============================================================================

locals {
  workflow_bucket = "workflow-input-${var.team_id}"
  workflow_table  = "workflow-output"
}

# ---- S3 입력 버킷 ----
resource "aws_s3_bucket" "workflow" {
  provider      = aws.sg
  bucket        = local.workflow_bucket
  force_destroy = true

  tags = {
    Module = "Workflow"
  }
}

resource "aws_s3_object" "workflow_data" {
  provider = aws.sg
  bucket   = aws_s3_bucket.workflow.id
  key      = "data.csv"
  source   = "${path.module}/files/workflow/data.csv"
  etag     = filemd5("${path.module}/files/workflow/data.csv")
}

# ---- DynamoDB 출력 테이블 ----
resource "aws_dynamodb_table" "workflow_output" {
  provider     = aws.sg
  name         = local.workflow_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = {
    Module = "Workflow"
  }
}

# ---- Lambda 실행 역할 ----
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "workflow_lambda" {
  provider           = aws.sg
  name               = "workflow-transform-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "workflow_lambda" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["*"]
  }
  statement {
    sid       = "S3Read"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.workflow.arn}/*"]
  }
  statement {
    sid       = "DynamoWrite"
    actions   = ["dynamodb:PutItem", "dynamodb:BatchWriteItem", "dynamodb:DescribeTable"]
    resources = [aws_dynamodb_table.workflow_output.arn]
  }
}

resource "aws_iam_role_policy" "workflow_lambda" {
  provider = aws.sg
  name     = "workflow-transform-policy"
  role     = aws_iam_role.workflow_lambda.id
  policy   = data.aws_iam_policy_document.workflow_lambda.json
}

# ---- Lambda 패키지 ----
data "archive_file" "workflow_lambda" {
  type        = "zip"
  source_file = "${path.module}/files/workflow/lambda_function.py"
  output_path = "${path.module}/build/workflow_lambda.zip"
}

resource "aws_lambda_function" "workflow_transform" {
  provider         = aws.sg
  function_name    = "workflow-transform"
  role             = aws_iam_role.workflow_lambda.arn
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  timeout          = 60
  filename         = data.archive_file.workflow_lambda.output_path
  source_code_hash = data.archive_file.workflow_lambda.output_base64sha256
  environment {
    variables = {
      TABLE_NAME = local.workflow_table
    }
  }

  tags = {
    Module = "Workflow"
  }

  depends_on = [aws_iam_role_policy.workflow_lambda]
}

# ---- Step Functions 역할 (lambda:InvokeFunction 만) ----
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "workflow_sfn" {
  provider           = aws.sg
  name               = "workflow-state-machine-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
}

data "aws_iam_policy_document" "workflow_sfn" {
  statement {
    sid       = "InvokeLambda"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.workflow_transform.arn]
  }
}

resource "aws_iam_role_policy" "workflow_sfn" {
  provider = aws.sg
  name     = "workflow-state-machine-policy"
  role     = aws_iam_role.workflow_sfn.id
  policy   = data.aws_iam_policy_document.workflow_sfn.json
}

# ---- Step Functions 상태 머신 (STANDARD) ----
resource "aws_sfn_state_machine" "workflow" {
  provider = aws.sg
  name     = "workflow-state-machine"
  type     = "STANDARD"
  role_arn = aws_iam_role.workflow_sfn.arn

  definition = jsonencode({
    Comment = "WSC 2026 workflow pipeline"
    StartAt = "ValidateInput"
    States = {
      ValidateInput = {
        Type = "Pass"
        Next = "TransformAndSave"
      }
      TransformAndSave = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Parameters = {
          FunctionName = aws_lambda_function.workflow_transform.arn
          "Payload.$"  = "$"
        }
        Next = "Success"
      }
      Success = {
        Type = "Succeed"
      }
    }
  })

  tags = {
    Module = "Workflow"
  }
}

# ---- Step Functions 실행 안내 (채점 [3-5] workflow-output 데이터 적재) ----
# 상태 머신 실행은 "런타임 동작"이므로 terraform 인프라 코드에 두지 않는다.
# (문제/채점 지침도 CloudShell 에서 start-execution 하도록 요구한다.)
# apply 후 아래 명령을 CloudShell/Bastion(Linux)에서 실행하여 데이터를 적재한다:
#
#   SFN_ARN=$(aws stepfunctions list-state-machines --region ap-southeast-1 \
#     --query "stateMachines[?name=='workflow-state-machine'].stateMachineArn | [0]" --output text)
#   aws stepfunctions start-execution --region ap-southeast-1 \
#     --state-machine-arn "$SFN_ARN" \
#     --input '{"bucket":"workflow-input-<비번호>","key":"data.csv"}'
#
# Bastion 의 deploy.sh 가 이 실행을 자동으로 수행한다(README 참고).
