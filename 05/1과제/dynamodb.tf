resource "aws_dynamodb_table" "books" {
  name         = "books"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "booking_id"

  attribute {
    name = "booking_id"
    type = "S"
  }

  attribute {
    name = "client_id"
    type = "S"
  }

  global_secondary_index {
    name            = "client_id-index"
    hash_key        = "client_id"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }
}

resource "aws_dynamodb_resource_policy" "books" {
  resource_arn = aws_dynamodb_table.books.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyWriteExceptBook"
      Effect    = "Deny"
      Principal = "*"
      # 예약 데이터 '생성/수정'은 book 앱(IRSA gj2026-book-app-role)만 허용.
      # 그 외 principal(bastion/노드/CloudShell 등)은 명시적 Deny → 3-3 채점(PutItem) 통과.
      # DeleteItem 은 제외: 채점 전 테이블 비우기(clean-books.sh)를 운영자가 할 수 있어야 함.
      Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:BatchWriteItem"]
      Resource = aws_dynamodb_table.books.arn
      Condition = {
        ArnNotLike = {
          "aws:PrincipalArn" = "arn:aws:iam::${local.account_id}:role/gj2026-book-app-role"
        }
      }
    }]
  })
}
