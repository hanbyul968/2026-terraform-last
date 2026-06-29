resource "aws_kms_key" "dynamodb" {
  description = "KMS key for skills-book-booking"
}

resource "aws_kms_alias" "dynamodb" {
  name          = "alias/skills-book-ddb"
  target_key_id = aws_kms_key.dynamodb.key_id
}

resource "aws_dynamodb_table" "booking" {
  name         = "skills-book-booking"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "booking_id"

  attribute {
    name = "booking_id"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }
}
