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
  default     = "102"
}

# ── S3 (input/ processed/ error/) ───────────────────────────────────
resource "aws_s3_bucket" "score" {
  bucket        = "wsc2026-student-score-bucket-${var.bibunho}"
  force_destroy = true
}
# 폴더 placeholder 는 Terraform 이 만들지 않는다.
#  - 새 채점기준표: 채점 시작 시 버킷/테이블 데이터가 남아 있으면 1-1·1-5·1-6 을 모두 오답 처리한다.
#    0바이트 폴더 마커도 객체이므로 남기지 않는다.
#  - 그럼에도 1-1 은 `aws s3 ls s3://$BUCKET/` 출력에 error/ input/ processed/ 3개 PRE 를 요구한다.
#    → 워크플로가 input/test.csv 를 processed/ 로 옮긴 뒤 input/ 마커를 복원(RestoreInputPrefix)하고,
#      error/ 는 검증 실패 4건, processed/ 는 test.csv 로 각각 채워져 3개 PRE 가 모두 표시된다.

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
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/score.zip"
}
resource "aws_lambda_function" "score" {
  function_name    = "wsc2026-student-score-function"
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
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
        Next       = "RestoreInputPrefix"
      }
      # input/ 의 마지막 객체가 processed/ 로 이동하면 'PRE input/' 이 사라진다.
      # 채점 1-1 은 error/ input/ processed/ 3개 PRE 를 요구하므로 0바이트 마커를 복원한다.
      RestoreInputPrefix = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:s3:putObject"
        Parameters = {
          Bucket = aws_s3_bucket.score.id
          Key    = "input/"
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
        Next       = "RestoreInputPrefixOnError"
      }
      RestoreInputPrefixOnError = {
        Type     = "Task"
        Resource = "arn:aws:states:::aws-sdk:s3:putObject"
        Parameters = {
          Bucket = aws_s3_bucket.score.id
          Key    = "input/"
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

# test.csv 업로드 → 이벤트 기반 워크플로(S3 알림→트리거 Lambda→Step Functions) 완료 대기.
#
# 최초 apply 시 aws_s3_bucket_notification 이 완전히 활성화되기 전에 업로드하면
# ObjectCreated 이벤트가 유실되어 워크플로가 시작되지 않는다(30초 대기로는 부족).
# 따라서 아래와 같이 견고하게 처리한다.
#   1) processed/·error/·input/test.csv 를 먼저 초기화 (재실행/중복 방지, idempotent)
#   2) 알림 전파를 위해 60초 대기 후 업로드 → 이벤트 기반 경로로 처리 유도
#   3) 최대 ~180초 동안 processed/test.csv 와 error/ 4개가 생성되는지 폴링
#   4) 알림이 끝내 동작하지 않으면(전파 실패) 이미 업로드된 input/test.csv 로
#      Step Functions 를 직접 1회 실행(재업로드 X → 중복 실행 방지)
#   5) 최종적으로 processed/test.csv 존재 + error/ 정확히 4개 + 1-1 PRE 3종 + 1-5 표본값
#      (STU1020 96.6 A)을 강제 검증한다. S3 알림의 at-least-once 중복 전달로 error 파일이
#      초과 생성된 경우 studentId 기준 1개씩만 남기고 정리한다.
#   6) 검증이 끝나면 S3 버킷과 DynamoDB 테이블을 비운다(새 채점기준표의 데이터 클렌징 조건).
#      채점위원이 input/test.csv 를 다시 업로드하면 동일 경로로 워크플로가 재실행된다.
#      수동 재클렌징은 `bash cleanup.sh` 사용.
resource "terraform_data" "upload_test_csv" {
  triggers_replace = [
    "v3-verify-then-cleanse", # 로직 개정: 강제 재실행용 버전 마커
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
      SM_ARN = aws_sfn_state_machine.score.arn
      DDB    = aws_dynamodb_table.score.name
      CSV    = "${path.module}/test.csv"
    }
    command = <<-EOT
      set -euo pipefail

      has_processed() { aws s3api head-object --bucket "$BUCKET" --key processed/test.csv --region "$REGION" >/dev/null 2>&1; }
      count_errors()  { aws s3api list-objects-v2 --bucket "$BUCKET" --prefix error/ --region "$REGION" --query 'length(Contents || `[]`)' --output text 2>/dev/null || echo 0; }

      reset_state() {
        aws s3 rm "s3://$BUCKET/processed/" --recursive --region "$REGION" >/dev/null 2>&1 || true
        aws s3 rm "s3://$BUCKET/error/"     --recursive --region "$REGION" >/dev/null 2>&1 || true
        aws s3 rm "s3://$BUCKET/input/test.csv"          --region "$REGION" >/dev/null 2>&1 || true
      }

      # error/ 에 studentId 당 1개만 남기고 중복 제거 (S3 알림 중복 전달 방어)
      dedup_errors() {
        local keys seen sid base
        keys=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix error/ --region "$REGION" --query 'Contents[].Key' --output text 2>/dev/null || true)
        seen=$(mktemp)
        for k in $keys; do
          base=$(basename "$k" .json)
          sid=$(printf '%s' "$base" | sed 's/.*_//')
          if grep -qxF "$sid" "$seen" 2>/dev/null; then
            aws s3 rm "s3://$BUCKET/$k" --region "$REGION" >/dev/null 2>&1 || true
          else
            printf '%s\n' "$sid" >> "$seen"
          fi
        done
        rm -f "$seen"
      }

      # Step Functions 직접 1회 실행 후 완료 대기 (fallback 전용, 재업로드 없음)
      direct_run() {
        aws s3api head-object --bucket "$BUCKET" --key input/test.csv --region "$REGION" >/dev/null 2>&1 || \
          aws s3 cp "$CSV" "s3://$BUCKET/input/test.csv" --region "$REGION" --only-show-errors
        local exec_arn st i
        exec_arn=$(aws stepfunctions start-execution --state-machine-arn "$SM_ARN" \
          --input '{"key":"input/test.csv"}' --region "$REGION" --query executionArn --output text)
        for i in $(seq 1 40); do
          st=$(aws stepfunctions describe-execution --execution-arn "$exec_arn" --region "$REGION" --query status --output text)
          case "$st" in
            SUCCEEDED) return 0 ;;
            FAILED|TIMED_OUT|ABORTED) echo "Step Functions execution $st" >&2; return 1 ;;
          esac
          sleep 3
        done
        echo "Step Functions execution did not finish in time" >&2
        return 1
      }

      # 1) 초기화 (이전 잔여물/중복 제거)
      echo "Resetting processed/, error/, input/test.csv for a clean run..."
      reset_state

      # 2) S3 이벤트 알림 전파 대기 후 업로드 (이벤트 기반 경로)
      echo "Waiting 60s for S3 event notification to become active..."
      sleep 60
      echo "Uploading test.csv to input/ (event-driven trigger)..."
      aws s3 cp "$CSV" "s3://$BUCKET/input/test.csv" --region "$REGION" --only-show-errors

      # 3) 이벤트 기반 처리 결과 폴링 (최대 ~180초)
      echo "Waiting for event-driven workflow to produce processed/test.csv (max ~180s)..."
      for attempt in $(seq 1 36); do
        if has_processed; then
          echo "Event-driven workflow completed."
          break
        fi
        sleep 5
      done

      # 4) 알림이 동작하지 않았으면 직접 실행 (재업로드 없이 기존 input/test.csv 사용)
      if ! has_processed; then
        echo "S3 notification did not trigger the workflow; starting Step Functions directly..."
        aws s3 rm "s3://$BUCKET/error/" --recursive --region "$REGION" >/dev/null 2>&1 || true
        direct_run || { echo "Workflow did not complete via direct execution" >&2; exit 1; }
      fi

      # 5) 중복 정리 + 최종 강제 검증
      dedup_errors
      if ! has_processed; then
        echo "ERROR: processed/test.csv is missing after workflow" >&2
        exit 1
      fi
      EC=$(count_errors)
      if [ "$EC" != "4" ]; then
        echo "ERROR: expected exactly 4 error objects, found $EC" >&2
        exit 1
      fi
      PREFIXES=$(aws s3 ls "s3://$BUCKET/" --region "$REGION" | awk '{print $2}' | tr '\n' ' ' | xargs)
      if [ "$PREFIXES" != "error/ input/ processed/" ]; then
        echo "ERROR: 1-1 prefixes mismatch (actual: $PREFIXES)" >&2
        exit 1
      fi
      ITEMS=$(aws dynamodb scan --table-name "$DDB" --region "$REGION" --select COUNT --query Count --output text)
      if [ "$ITEMS" -lt 1 ]; then
        echo "ERROR: DynamoDB has no processed item" >&2
        exit 1
      fi
      AVG=$(aws dynamodb get-item --table-name "$DDB" --region "$REGION" \
        --key '{"studentId":{"S":"STU1020"},"examDate":{"S":"2026-05-30"}}' \
        --query "Item.[studentId.S,average.N,grade.S]" --output text | tr '\t' ' ' | xargs)
      if [ "$AVG" != "STU1020 96.6 A" ]; then
        echo "ERROR: 1-5 sample mismatch (actual: $AVG)" >&2
        exit 1
      fi
      echo "Verified: 1-1 prefixes / 1-5 ($AVG, processed/test.csv) / 1-6 (error objects=$EC) OK."

      # 6) 채점 전 데이터 클렌징 (새 채점기준표 필수 조건)
      #    "채점 시작 시 S3 버킷과 DynamoDB 데이터가 남아 있으면 1-1·1-5·1-6 을 모두 오답 처리"
      #    → 검증이 끝나면 버킷과 테이블을 비운다. 채점 시 채점위원이 input/test.csv 를
      #      다시 업로드하면 같은 경로로 워크플로가 재실행된다.
      echo "Cleansing S3 bucket and DynamoDB table for grading..."
      aws s3 rm "s3://$BUCKET/" --recursive --region "$REGION" >/dev/null 2>&1 || true
      while :; do
        KEYS=$(aws dynamodb scan --table-name "$DDB" --region "$REGION" \
          --projection-expression "studentId,examDate" \
          --query 'Items[*]' --output json)
        COUNT=$(printf '%s' "$KEYS" | jq 'length')
        [ "$COUNT" -eq 0 ] && break
        printf '%s' "$KEYS" | jq -c '.[]' | while read -r k; do
          aws dynamodb delete-item --table-name "$DDB" --region "$REGION" --key "$k" >/dev/null
        done
      done
      LEFT_S3=$(aws s3api list-objects-v2 --bucket "$BUCKET" --region "$REGION" --query 'length(Contents || `[]`)' --output text 2>/dev/null || echo 0)
      LEFT_DDB=$(aws dynamodb scan --table-name "$DDB" --region "$REGION" --select COUNT --query Count --output text)
      echo "Cleansed: S3 objects=$LEFT_S3, DynamoDB items=$LEFT_DDB (both must be 0)"
      [ "$LEFT_S3" = "0" ] && [ "$LEFT_DDB" = "0" ]
    EOT
  }
  depends_on = [aws_s3_bucket_notification.eb]
}

output "bucket" { value = aws_s3_bucket.score.id }
output "state_machine_arn" { value = aws_sfn_state_machine.score.arn }
