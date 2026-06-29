# =============================================================================
# 03/2과제 Module 4. Workflow  | Region: ap-southeast-1 (싱가포르)
#   이커머스 주문 처리 파이프라인
#   S3(주문데이터) -> Step Functions(Standard) -> Lambda(검증/결제) -> DynamoDB
#   S3/DynamoDB 는 Lambda 없이 AWS SDK 직접 통합으로 호출.
#   ※ 자체 state.
# =============================================================================
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.60" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

provider "aws" {
  region = "ap-southeast-1"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  bucket_name   = "wsc2026-order-pipeline"
  orders_table  = "wsc2026-orders"
  inv_table     = "wsc2026-inventory"
  hist_table    = "wsc2026-pipeline-history"
  validator_fn  = "wsc2026-order-validator"
  payment_fn    = "wsc2026-payment-processor"
  state_machine = "wsc2026-order-pipeline"
}

# ─────────────────────────────────────────────
# S3 주문 버킷 (버전관리 + incoming/ + sample-orders.json)
# ─────────────────────────────────────────────
resource "aws_s3_bucket" "orders" {
  bucket        = local.bucket_name
  force_destroy = true
  tags          = { Name = local.bucket_name }
}

resource "aws_s3_bucket_versioning" "orders" {
  bucket = aws_s3_bucket.orders.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "incoming_prefix" {
  bucket  = aws_s3_bucket.orders.id
  key     = "incoming/"
  content = ""
}

resource "aws_s3_object" "sample_orders" {
  bucket = aws_s3_bucket.orders.id
  key    = "incoming/sample-orders.json"
  source = "${path.module}/assets/sample-orders.json"
  etag   = filemd5("${path.module}/assets/sample-orders.json")
}

# ─────────────────────────────────────────────
# DynamoDB 테이블 3개 (모두 On-Demand)
# ─────────────────────────────────────────────
resource "aws_dynamodb_table" "orders" {
  name         = local.orders_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "order_id"
  range_key    = "ordered_at"

  attribute {
    name = "order_id"
    type = "S"
  }
  attribute {
    name = "ordered_at"
    type = "S"
  }
  tags = { Name = local.orders_table }
}

resource "aws_dynamodb_table" "inventory" {
  name         = local.inv_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "product_id"

  attribute {
    name = "product_id"
    type = "S"
  }
  tags = { Name = local.inv_table }
}

resource "aws_dynamodb_table" "history" {
  name         = local.hist_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "execution_id"
  range_key    = "started_at"

  attribute {
    name = "execution_id"
    type = "S"
  }
  attribute {
    name = "started_at"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
  tags = { Name = local.hist_table }
}

# Inventory 초기 재고 적재 (inventory-seed.json)
locals {
  inventory_seed = jsondecode(file("${path.module}/assets/inventory-seed.json"))
}

resource "aws_dynamodb_table_item" "inventory_seed" {
  for_each   = { for item in local.inventory_seed : item.product_id => item }
  table_name = aws_dynamodb_table.inventory.name
  hash_key   = aws_dynamodb_table.inventory.hash_key

  item = jsonencode({
    product_id = { S = each.value.product_id }
    name       = { S = each.value.name }
    stock      = { N = tostring(each.value.stock) }
    unit_price = { N = tostring(each.value.unit_price) }
  })
}

# ─────────────────────────────────────────────
# Lambda 실행 역할 (검증/결제 공용 - 최소 권한: 로그만)
# ─────────────────────────────────────────────
resource "aws_iam_role" "lambda" {
  name = "wsc2026-order-lambda-role"
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
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ─────────────────────────────────────────────
# Lambda: wsc2026-order-validator / wsc2026-payment-processor (python3.13)
# ─────────────────────────────────────────────
data "archive_file" "validator" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/validator"
  output_path = "${path.module}/build/validator.zip"
}

resource "aws_lambda_function" "validator" {
  function_name    = local.validator_fn
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.13"
  filename         = data.archive_file.validator.output_path
  source_code_hash = data.archive_file.validator.output_base64sha256
  timeout          = 30
  tags             = { Name = local.validator_fn }
}

data "archive_file" "payment" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/payment"
  output_path = "${path.module}/build/payment.zip"
}

resource "aws_lambda_function" "payment" {
  function_name    = local.payment_fn
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.13"
  filename         = data.archive_file.payment.output_path
  source_code_hash = data.archive_file.payment.output_base64sha256
  timeout          = 30
  tags             = { Name = local.payment_fn }
}

# ─────────────────────────────────────────────
# Step Functions 실행 역할 (Lambda invoke + S3 read + DynamoDB write)
# ─────────────────────────────────────────────
resource "aws_iam_role" "sfn" {
  name = "wsc2026-order-pipeline-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  name = "wsc2026-order-pipeline-policy"
  role = aws_iam_role.sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeLambda"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.validator.arn, aws_lambda_function.payment.arn]
      },
      {
        Sid      = "S3Read"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.orders.arn}/*"]
      },
      {
        Sid    = "DynamoWrite"
        Effect = "Allow"
        Action = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"]
        Resource = [
          aws_dynamodb_table.orders.arn,
          aws_dynamodb_table.inventory.arn,
          aws_dynamodb_table.history.arn,
        ]
      }
    ]
  })
}

# ─────────────────────────────────────────────
# Step Functions State Machine (Standard) : wsc2026-order-pipeline
# ─────────────────────────────────────────────
resource "aws_sfn_state_machine" "pipeline" {
  name     = local.state_machine
  type     = "STANDARD"
  role_arn = aws_iam_role.sfn.arn

  definition = jsonencode({
    Comment = "WSC2026 order processing pipeline"
    StartAt = "FetchOrders"
    States = {
      FetchOrders = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:s3:getObject"
        Parameters = {
          "Bucket.$" = "$.bucket"
          "Key.$"    = "$.key"
        }
        ResultSelector = {
          "parsed.$" = "States.StringToJson($.Body)"
        }
        ResultPath = "$.orderData"
        Retry = [{
          ErrorEquals     = ["States.ALL"]
          IntervalSeconds = 2
          MaxAttempts     = 2
          BackoffRate     = 2.0
        }]
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "PipelineFailed"
        }]
        Next = "ValidateOrders"
      }

      ValidateOrders = {
        Type           = "Map"
        ItemsPath      = "$.orderData.parsed"
        MaxConcurrency = 5
        ResultPath     = "$.validationResults"
        ItemProcessor = {
          ProcessorConfig = { Mode = "INLINE" }
          StartAt         = "ValidateOne"
          States = {
            ValidateOne = {
              Type     = "Task"
              Resource = "arn:aws:states:::lambda:invoke"
              Parameters = {
                FunctionName = aws_lambda_function.validator.arn
                "Payload.$"  = "$"
              }
              OutputPath = "$.Payload"
              Retry = [{
                ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException", "States.TaskFailed"]
                IntervalSeconds = 2
                MaxAttempts     = 2
                BackoffRate     = 2.0
              }]
              End = true
            }
          }
        }
        Catch = [{
          ErrorEquals = ["States.ALL"]
          ResultPath  = "$.error"
          Next        = "PipelineFailed"
        }]
        Next = "ProcessAndStore"
      }

      ProcessAndStore = {
        Type           = "Map"
        ItemsPath      = "$.validationResults"
        MaxConcurrency = 10
        ResultPath     = "$.processResults"
        ItemProcessor = {
          ProcessorConfig = { Mode = "INLINE" }
          StartAt         = "CheckValid"
          States = {
            CheckValid = {
              Type = "Choice"
              Choices = [{
                Variable      = "$.valid"
                BooleanEquals = true
                Next          = "ProcessPayment"
              }]
              Default = "SkipInvalid"
            }

            SkipInvalid = {
              Type   = "Pass"
              Result = { processed = false }
              End    = true
            }

            ProcessPayment = {
              Type     = "Task"
              Resource = "arn:aws:states:::lambda:invoke"
              Parameters = {
                FunctionName = aws_lambda_function.payment.arn
                "Payload.$"  = "$.order"
              }
              ResultSelector = { "order.$" = "$.Payload" }
              ResultPath     = "$.payment"
              Catch = [{
                ErrorEquals = ["States.ALL"]
                ResultPath  = "$.error"
                Next        = "SkipError"
              }]
              Next = "StoreOrder"
            }

            StoreOrder = {
              Type     = "Task"
              Resource = "arn:aws:states:::dynamodb:putItem"
              Parameters = {
                TableName = aws_dynamodb_table.orders.name
                Item = {
                  "order_id"       = { "S.$" = "$.payment.order.order_id" }
                  "ordered_at"     = { "S.$" = "$.payment.order.ordered_at" }
                  "product_id"     = { "S.$" = "$.payment.order.product_id" }
                  "quantity"       = { "N.$" = "States.Format('{}', $.payment.order.quantity)" }
                  "unit_price"     = { "N.$" = "States.Format('{}', $.payment.order.unit_price)" }
                  "total_amount"   = { "N.$" = "States.Format('{}', $.payment.order.total_amount)" }
                  "total_usd"      = { "N.$" = "States.Format('{}', $.payment.order.total_usd)" }
                  "payment_status" = { "S.$" = "$.payment.order.payment_status" }
                  "processed_at"   = { "S.$" = "$.payment.order.processed_at" }
                }
              }
              ResultPath = "$.storeResult"
              Retry = [{
                ErrorEquals     = ["DynamoDB.ThrottlingException", "DynamoDB.InternalServerError", "States.TaskFailed"]
                IntervalSeconds = 1
                MaxAttempts     = 3
                BackoffRate     = 2.0
              }]
              Catch = [{
                ErrorEquals = ["States.ALL"]
                ResultPath  = "$.error"
                Next        = "SkipError"
              }]
              Next = "UpdateInventory"
            }

            UpdateInventory = {
              Type     = "Task"
              Resource = "arn:aws:states:::dynamodb:updateItem"
              Parameters = {
                TableName = aws_dynamodb_table.inventory.name
                Key = {
                  "product_id" = { "S.$" = "$.payment.order.product_id" }
                }
                UpdateExpression = "SET stock = stock - :q"
                ExpressionAttributeValues = {
                  ":q" = { "N.$" = "States.Format('{}', $.payment.order.quantity)" }
                }
              }
              ResultPath = "$.invResult"
              Retry = [{
                ErrorEquals     = ["DynamoDB.ThrottlingException", "DynamoDB.InternalServerError", "States.TaskFailed"]
                IntervalSeconds = 1
                MaxAttempts     = 3
                BackoffRate     = 2.0
              }]
              Catch = [{
                ErrorEquals = ["States.ALL"]
                ResultPath  = "$.error"
                Next        = "SkipError"
              }]
              Next = "ProcessedOk"
            }

            ProcessedOk = {
              Type = "Pass"
              Parameters = {
                "processed"    = true
                "expires_at.$" = "$.payment.order.expires_at"
              }
              End = true
            }

            SkipError = {
              Type   = "Pass"
              Result = { processed = false }
              End    = true
            }
          }
        }
        Next = "RecordResult"
      }

      RecordResult = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:putItem"
        Parameters = {
          TableName = aws_dynamodb_table.history.name
          Item = {
            "execution_id"     = { "S.$" = "$$.Execution.Id" }
            "started_at"       = { "S.$" = "$$.Execution.StartTime" }
            "status"           = { "S" = "COMPLETED" }
            "total_orders"     = { "N.$" = "States.Format('{}', States.ArrayLength($.orderData.parsed))" }
            "valid_orders"     = { "N.$" = "States.Format('{}', States.ArrayLength($.validationResults))" }
            "processed_orders" = { "N.$" = "States.Format('{}', States.ArrayLength($.processResults))" }
            "expires_at"       = { "N.$" = "States.Format('{}', $.processResults[0].expires_at)" }
          }
        }
        End = true
      }

      PipelineFailed = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:putItem"
        Parameters = {
          TableName = aws_dynamodb_table.history.name
          Item = {
            "execution_id" = { "S.$" = "$$.Execution.Id" }
            "started_at"   = { "S.$" = "$$.Execution.StartTime" }
            "status"       = { "S" = "FAILED" }
            "error"        = { "S.$" = "States.Format('{}', $.error.Error)" }
            "cause"        = { "S.$" = "States.Format('{}', $.error.Cause)" }
          }
        }
        Next = "FailState"
      }

      FailState = {
        Type  = "Fail"
        Error = "PipelineFailed"
        Cause = "Unrecoverable error in FetchOrders or ValidateOrders"
      }
    }
  })

  tags = { Name = local.state_machine }
}

# ─────────────────────────────────────────────
# Outputs
# ─────────────────────────────────────────────
output "bucket_name" {
  value = aws_s3_bucket.orders.bucket
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.pipeline.arn
}

output "start_execution_input" {
  value = "{\"bucket\":\"${local.bucket_name}\",\"key\":\"incoming/sample-orders.json\"}"
}
