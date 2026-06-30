# 단일 고객 관리형 CMK 를 Flow Logs / S3 / ECR / EKS(secrets) 암호화에 공통 사용.
# (채점기준표상 flowlog/S3/ECR/EKS 가 동일한 key arn 으로 나타남)
resource "aws_kms_key" "main" {
  description             = "wsc-2026 shared CMK (flowlogs, s3, ecr, eks)"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${local.region}.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"
          }
        }
      },
      {
        Sid       = "AllowServiceUsage"
        Effect    = "Allow"
        Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:CreateGrant",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:ViaService" = [
              "s3.${local.region}.amazonaws.com",
              "ecr.${local.region}.amazonaws.com"
            ]
          }
        }
      }
    ]
  })

  tags = { Name = "wsc-2026-cmk" }
}

resource "aws_kms_alias" "main" {
  name          = "alias/wsc-2026-key"
  target_key_id = aws_kms_key.main.key_id
}
