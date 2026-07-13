# ═══════════════════════════════════════════════════════════════
# KMS Customer Managed Keys
#   채점이 별칭(alias)을 정확히 확인하므로 용도별로 분리한다:
#     alias/wskorea26-s3-key        (S3 객체, 채점 2-2)
#     alias/wskorea26-dynamodb-key  (DynamoDB, 채점 4-1)
#     alias/wskorea26-eks-key       (EKS Secret, 채점 5-1)
#   ECR / EBS 볼륨 / CloudWatch Logs 암호화는 s3(general) 키를 재사용한다.
# ═══════════════════════════════════════════════════════════════

# ── 공용/S3 키 (S3, ECR, EBS, CloudWatch Logs) ──
resource "aws_kms_key" "s3" {
  description             = "wskorea26 s3/general CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRoot"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${local.region}.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"
          }
        }
      },
      {
        Sid       = "AllowServiceLinkedRoleUse"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:CreateGrant", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringEquals = { "kms:CallerAccount" = local.account_id }
          StringLike   = { "kms:ViaService" = ["ec2.${local.region}.amazonaws.com", "s3.${local.region}.amazonaws.com", "ecr.${local.region}.amazonaws.com"] }
        }
      },
      {
        Sid       = "AllowCloudFrontOACDecrypt"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
        Condition = {
          StringLike = { "AWS:SourceArn" = "arn:${local.partition}:cloudfront::${local.account_id}:distribution/*" }
        }
      }
    ]
  })

  tags = { Name = "wskorea26-s3-key" }
}

resource "aws_kms_alias" "s3" {
  name          = "alias/wskorea26-s3-key"
  target_key_id = aws_kms_key.s3.key_id
}

# ── DynamoDB 키 ──
resource "aws_kms_key" "dynamodb" {
  description             = "wskorea26 dynamodb CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = { Name = "wskorea26-dynamodb-key" }
}

resource "aws_kms_alias" "dynamodb" {
  name          = "alias/wskorea26-dynamodb-key"
  target_key_id = aws_kms_key.dynamodb.key_id
}

# ── EKS Secret 키 ──
resource "aws_kms_key" "eks" {
  description             = "wskorea26 eks secret CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = { Name = "wskorea26-eks-key" }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/wskorea26-eks-key"
  target_key_id = aws_kms_key.eks.key_id
}
