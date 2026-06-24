# ═══════════════════════════════════════════════════════════════
# KMS Customer Managed Keys
#  과제는 여러 서비스에서 CMK(Customer Managed Key) 암호화를 요구한다.
#  키를 용도별로 분리해도 되지만, 관리를 위해 공용 CMK 1개 + 로그용 정책을 둔다.
#  (DynamoDB/S3/ECR/EKS secrets/EBS/CloudWatch Logs 모두 이 키 사용)
# ═══════════════════════════════════════════════════════════════

resource "aws_kms_key" "main" {
  description             = "wsc shared CMK"
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
        # EBS CSI / AutoScaling 가 노드 볼륨 암호화에 grant 를 생성할 수 있도록 허용
        Sid       = "AllowServiceLinkedRoleUse"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:CreateGrant", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringEquals = { "kms:CallerAccount" = local.account_id }
          StringLike   = { "kms:ViaService" = ["ec2.${local.region}.amazonaws.com", "s3.${local.region}.amazonaws.com", "ecr.${local.region}.amazonaws.com", "dynamodb.${local.region}.amazonaws.com"] }
        }
      }
    ]
  })

  tags = { Name = "wsc-cmk" }
}

resource "aws_kms_alias" "main" {
  name          = "alias/wsc-key"
  target_key_id = aws_kms_key.main.key_id
}
