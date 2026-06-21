# =============================================================================
# 9. NoSQL 데이터베이스 (DynamoDB)
#  - 테이블명: <id>-booking-table
#  - PK: client_id (S)
#  - BillingMode: PAY_PER_REQUEST (On-demand)
# =============================================================================

resource "aws_dynamodb_table" "booking" {
  name         = local.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "client_id"

  attribute {
    name = "client_id"
    type = "S"
  }

  tags = {
    Name = local.table_name
  }
}
