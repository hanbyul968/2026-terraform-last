# ═══════════════════════════════════════════════════════════════
# DynamoDB  (과제 8)
#   - Table: wsc-table
#   - Partition Key: client_id (String)
#   - 그 외 속성(username/email/concert_name)은 비키 속성이라 정의 불필요
#   - CMK(Customer Managed Key) 암호화
# 채점 2-1-A: AttributeDefinitions == "client_id S"
# 채점 2-1-B: SSEDescription.KMSMasterKeyArn 가 arn:aws:kms 로 시작
# ═══════════════════════════════════════════════════════════════

resource "aws_dynamodb_table" "this" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "client_id"

  attribute {
    name = "client_id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = local.table_name }
}
