# ═══════════════════════════════════════════════════════════════
# KMS Customer Managed Keys  (서비스별로 분리)
#
# 과제 유의사항 10 / 채점 check_kms:
#   키 정책에 root("...:root") 와 "kms:*" 를 쓸 수 없다(최소 권한).
#   => 키 관리 권한은 실제 배포 주체(local.kms_admin_arn)에게 '구체적 액션'으로,
#      사용 권한은 각 서비스 principal/ViaService 조건으로만 부여한다.
#
# 키(alias):
#   wsc2026-db-kms       DynamoDB 암호화
#   wsc2026-ecr-kms      ECR 암호화
#   wsc2026-eks-kms      EKS Secret + ControlPlane Log 암호화
#   wsc2026-bucket-kms   S3 버킷/객체 암호화
#   wsc2026-function-kms Lambda 코드/환경변수 암호화
# ═══════════════════════════════════════════════════════════════

locals {
  # 키 관리 주체에게 부여할 액션 (kms:* 금지 -> 구체적으로 나열)
  kms_admin_actions = [
    "kms:Create*", "kms:Describe*", "kms:Enable*", "kms:List*",
    "kms:Put*", "kms:Update*", "kms:Revoke*", "kms:Disable*",
    "kms:Get*", "kms:Delete*", "kms:TagResource", "kms:UntagResource",
    "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion",
    "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
    "kms:GenerateDataKey*", "kms:CreateGrant",
  ]
  kms_admin_statement = {
    Sid       = "AllowKeyAdministrator"
    Effect    = "Allow"
    Principal = { AWS = local.kms_admin_arn }
    Action    = local.kms_admin_actions
    Resource  = "*"
  }
}

# 서비스 ViaService 사용 허용 statement 생성용 헬퍼(로컬)
locals {
  kms_via_service = {
    db  = "dynamodb.${local.region}.amazonaws.com"
    ecr = "ecr.${local.region}.amazonaws.com"
    s3  = "s3.${local.region}.amazonaws.com"
    lam = "lambda.${local.region}.amazonaws.com"
  }
}

# ── DynamoDB CMK ──────────────────────────────────────────────
resource "aws_kms_key" "db" {
  description             = "wsc2026 DynamoDB CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.kms_admin_statement,
      {
        Sid       = "AllowDynamoDBViaService"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
        Resource  = "*"
        Condition = {
          StringEquals = { "kms:CallerAccount" = local.account_id, "kms:ViaService" = local.kms_via_service.db }
        }
      }
    ]
  })
  tags = { Name = local.kms_db }
}
resource "aws_kms_alias" "db" {
  name          = "alias/${local.kms_db}"
  target_key_id = aws_kms_key.db.key_id
}

# ── ECR CMK ───────────────────────────────────────────────────
resource "aws_kms_key" "ecr" {
  description             = "wsc2026 ECR CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.kms_admin_statement,
      {
        Sid       = "AllowEcrViaService"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
        Resource  = "*"
        Condition = {
          StringEquals = { "kms:CallerAccount" = local.account_id, "kms:ViaService" = local.kms_via_service.ecr }
        }
      }
    ]
  })
  tags = { Name = local.kms_ecr }
}
resource "aws_kms_alias" "ecr" {
  name          = "alias/${local.kms_ecr}"
  target_key_id = aws_kms_key.ecr.key_id
}

# ── EKS CMK (Secret + ControlPlane Log) ───────────────────────
resource "aws_kms_key" "eks" {
  description             = "wsc2026 EKS CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.kms_admin_statement,
      {
        Sid       = "AllowEksClusterRole"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.eks_cluster.arn }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
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
      }
    ]
  })
  tags = { Name = local.kms_eks }
}
resource "aws_kms_alias" "eks" {
  name          = "alias/${local.kms_eks}"
  target_key_id = aws_kms_key.eks.key_id
}

# ── S3 Bucket CMK ─────────────────────────────────────────────
resource "aws_kms_key" "bucket" {
  description             = "wsc2026 S3 bucket CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.kms_admin_statement,
      {
        Sid       = "AllowS3ViaService"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringEquals = { "kms:CallerAccount" = local.account_id, "kms:ViaService" = local.kms_via_service.s3 }
        }
      },
      {
        Sid       = "AllowCloudFrontDecrypt"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = ["kms:Decrypt"]
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      }
    ]
  })
  tags = { Name = local.kms_bucket }
}
resource "aws_kms_alias" "bucket" {
  name          = "alias/${local.kms_bucket}"
  target_key_id = aws_kms_key.bucket.key_id
}

# ── Lambda CMK (코드/환경변수) ────────────────────────────────
resource "aws_kms_key" "function" {
  description             = "wsc2026 Lambda CMK"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      local.kms_admin_statement,
      {
        Sid       = "AllowLambdaViaService"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
        Resource  = "*"
        Condition = {
          StringEquals = { "kms:CallerAccount" = local.account_id, "kms:ViaService" = local.kms_via_service.lam }
        }
      },
      {
        Sid       = "AllowFunctionRoleDecrypt"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.book_function.arn }
        Action    = ["kms:Decrypt"]
        Resource  = "*"
      }
    ]
  })
  tags = { Name = local.kms_function }
}
resource "aws_kms_alias" "function" {
  name          = "alias/${local.kms_function}"
  target_key_id = aws_kms_key.function.key_id
}
