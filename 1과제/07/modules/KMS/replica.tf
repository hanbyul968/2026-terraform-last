# Replica key in us-east-1 (for WAF logs)
resource "aws_kms_replica_key" "platform_replica" {
  provider                = aws.us_east_1
  description             = "Replica of Platform key in us-east-1"
  deletion_window_in_days = 7
  primary_key_arn         = aws_kms_key.platform.arn

  # Multi-Region replica key policies are managed independently from the
  # primary key policy. Permit only the required us-east-1 WAF log group.
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
        Sid       = "AllowWafCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.us-east-1.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnEquals = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:aws-waf-logs-unicorn"
          }
        }
      }
    ]
  })
}

resource "aws_kms_alias" "platform_replica" {
  provider      = aws.us_east_1
  name          = "alias/unicorn-kms-platform"
  target_key_id = aws_kms_replica_key.platform_replica.key_id
}
