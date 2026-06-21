resource "aws_kms_key" "eks" {
  description = "EKS Secrets Encryption"
}

resource "aws_kms_alias" "eks" {
  name          = "alias/gj2026-eks-key"
  target_key_id = aws_kms_key.eks.key_id
}

resource "aws_kms_key" "dynamodb" {
  description = "DynamoDB Encryption"
}

resource "aws_kms_alias" "dynamodb" {
  name          = "alias/gj2026-db-key"
  target_key_id = aws_kms_key.dynamodb.key_id
}

resource "aws_kms_key" "s3" {
  description = "S3 Encryption"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudFront"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
        Condition = {
          ArnLike = { "AWS:SourceArn" = "arn:aws:cloudfront::${local.account_id}:distribution/*" }
        }
      }
    ]
  })
}

resource "aws_kms_alias" "s3" {
  name          = "alias/gj2026-s3-key"
  target_key_id = aws_kms_key.s3.key_id
}
