# ═══════════════════════════════════════════════════════════════
# DynamoDB  (과제 7)
#   - Table: wskorea26-data-table
#   - Partition Key: client_id (S)
#   - 삭제 방지(DeletionProtection) 활성화
#   - KMS(wskorea26-dynamodb-key) 암호화
#   - GSI: concert_name(HASH) + created_at(RANGE)  -> Lambda 조회(최신순)용
# 채점 4-1: client_id HASH / DeletionProtectionEnabled True / alias/wskorea26-dynamodb-key
# ═══════════════════════════════════════════════════════════════

resource "aws_dynamodb_table" "this" {
  name                        = local.table_name
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "client_id"
  deletion_protection_enabled = true

  attribute {
    name = "client_id"
    type = "S"
  }
  attribute {
    name = "concert_name"
    type = "S"
  }
  attribute {
    name = "created_at"
    type = "S"
  }

  # Lambda 가 concert_name 으로 조회 + created_at 최신순 정렬(ScanIndexForward=false)
  global_secondary_index {
    name            = local.gsi_name
    hash_key        = "concert_name"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = local.table_name }
}
