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
      Action    = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem", "dynamodb:BatchWriteItem"]
      Resource  = aws_dynamodb_table.books.arn
      # 스펙: 쓰기는 book 애플리케이션(IRSA gj2026-book-app-role)만 허용.
      # 그 외 모든 principal(bastion/노드/CloudShell 등)은 명시적 Deny.
      Condition = {
        ArnNotLike = {
          "aws:PrincipalArn" = "arn:aws:iam::${local.account_id}:role/gj2026-book-app-role"
        }
      }
    }]
  })
}
