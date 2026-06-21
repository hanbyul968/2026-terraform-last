data "aws_caller_identity" "current" {}

resource "aws_kms_key" "db" {
  description             = "KMS key for DynamoDB"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = { Name = "worldpay-db-key" }
}

resource "aws_kms_alias" "db" {
  name          = var.db_key_alias
  target_key_id = aws_kms_key.db.key_id
}

resource "aws_kms_key" "s3" {
  description             = "KMS key for S3"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudFrontService"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
      }
    ]
  })

  tags = { Name = "worldpay-s3-key" }
}

resource "aws_kms_alias" "s3" {
  name          = var.s3_key_alias
  target_key_id = aws_kms_key.s3.key_id
}
