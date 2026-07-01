# ═══════════════════════════════════════════════════════════════
# DynamoDB  (과제 5)
#   - Table: wsc2026-book-table / PK client_id (S)
#   - PAY_PER_REQUEST, CMK(wsc2026-db-kms) 암호화
#   - 삭제 방지(Deletion Protection) 활성화
#   - PITR 활성화 (최장 35일 복구)
#   - GSI: booking_id 로 조회 (booking_id-index)
#   - 리소스 기반 정책: Pod=PutItem, Lambda=Query (최소 권한)
#
# 채점 2-1:
#   client_id PAY_PER_REQUEST KMS True booking_id / ENABLED 35 ENABLED
#   dynamodb:PutItem : wsc2026-book-pod-role
#   dynamodb:Query   : wsc2026-book-function-role
# ═══════════════════════════════════════════════════════════════

resource "aws_dynamodb_table" "this" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "client_id"

  attribute {
    name = "client_id"
    type = "S"
  }
  attribute {
    name = "booking_id"
    type = "S"
  }

  global_secondary_index {
    name            = "booking_id-index"
    hash_key        = "booking_id"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = local.kms_db_arn
  }

  point_in_time_recovery {
    enabled                 = true
    recovery_period_in_days = 35
  }

  deletion_protection_enabled = true

  tags = { Name = local.table_name }
}

# ── 리소스 기반 정책 (최소 권한) ──────────────────────────────
resource "aws_dynamodb_resource_policy" "this" {
  resource_arn = aws_dynamodb_table.this.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PodPut"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.book_pod.arn }
        Action    = "dynamodb:PutItem"
        Resource  = aws_dynamodb_table.this.arn
      },
      {
        Sid       = "FunctionQuery"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.book_function.arn }
        Action    = "dynamodb:Query"
        Resource  = [aws_dynamodb_table.this.arn, "${aws_dynamodb_table.this.arn}/index/booking_id-index"]
      }
    ]
  })
}
