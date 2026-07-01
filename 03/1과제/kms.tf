# ═══════════════════════════════════════════════════════════════
# KMS Customer Managed Keys  (서비스별 분리)
#
# 과제 유의사항 10 / 채점 check_kms:
#   키 정책에 root("...:root") 와 "kms:*" 금지(최소 권한).
#   => 관리 권한은 local.kms_admin_arn(배포 역할) 에게 '구체적 액션'으로,
#      사용 권한은 서비스 ViaService / 역할 principal 로만.
#
# ── 두 가지 모드 ─────────────────────────────────────────────
#   reuse_kms = false (기본, 깨끗한 계정/대회):
#       아래 aws_kms_key/alias 를 '신규 생성'. 관리자=배포 역할(지속)이라
#       세션 종료로 잠기지 않음.
#   reuse_kms = true (이 연습 계정 전용, reuse.auto.tfvars):
#       이전 배포가 남긴 '잠긴' 키를 재사용. 잠긴 키는 DescribeKey 조차
#       거부되어 data source 로도 못 읽으므로 var.kms_key_arns 로 ARN 직접 지정.
#       (별칭은 이미 존재하므로 새로 만들지 않음)
#
# alias(과제 고정값, 채점 check_kms 가 alias 로 조회):
#   wsc2026-db-kms  ecr-kms  eks-kms  bucket-kms  function-kms
# ═══════════════════════════════════════════════════════════════

variable "reuse_kms" {
  description = "true=기존 잠긴 CMK 재사용(ARN 직접), false=신규 생성(기본, 대회/깨끗한 계정)"
  type        = bool
  default     = false
}

variable "kms_key_arns" {
  description = "reuse_kms=true 일 때 재사용할 기존 CMK ARN(alias 별). 잠긴 키라 data source 로 못 읽어 직접 지정."
  type        = map(string)
  default = {
    db       = "arn:aws:kms:ap-northeast-2:640107381732:key/9be955fb-22e3-437c-8bc4-4ad2c269d2c6"
    ecr      = "arn:aws:kms:ap-northeast-2:640107381732:key/72f4e6ce-a4aa-4f5b-8dfa-8c802af47b21"
    eks      = "arn:aws:kms:ap-northeast-2:640107381732:key/6815784c-d690-4d3a-b25a-819041588464"
    bucket   = "arn:aws:kms:ap-northeast-2:640107381732:key/99998859-d8bf-42db-89e6-acac7e8b69a1"
    function = "arn:aws:kms:ap-northeast-2:640107381732:key/a7afe16b-1821-49b2-898a-9555bd6568bb"
  }
}

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
  kms_via_service = {
    db  = "dynamodb.${local.region}.amazonaws.com"
    ecr = "ecr.${local.region}.amazonaws.com"
    s3  = "s3.${local.region}.amazonaws.com"
    lam = "lambda.${local.region}.amazonaws.com"
  }
  kc = var.reuse_kms ? 0 : 1 # 신규 생성 개수(reuse 면 0)

  # 각 서비스가 쓸 키 ARN: reuse 면 지정 ARN, 아니면 새로 만든 키
  kms_db_arn       = var.reuse_kms ? var.kms_key_arns["db"] : aws_kms_key.db[0].arn
  kms_ecr_arn      = var.reuse_kms ? var.kms_key_arns["ecr"] : aws_kms_key.ecr[0].arn
  kms_eks_arn      = var.reuse_kms ? var.kms_key_arns["eks"] : aws_kms_key.eks[0].arn
  kms_bucket_arn   = var.reuse_kms ? var.kms_key_arns["bucket"] : aws_kms_key.bucket[0].arn
  kms_function_arn = var.reuse_kms ? var.kms_key_arns["function"] : aws_kms_key.function[0].arn
}

# ── DynamoDB CMK ──────────────────────────────────────────────
resource "aws_kms_key" "db" {
  count                   = local.kc
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
  count         = local.kc
  name          = "alias/${local.kms_db}"
  target_key_id = aws_kms_key.db[0].key_id
}

# ── ECR CMK ───────────────────────────────────────────────────
resource "aws_kms_key" "ecr" {
  count                   = local.kc
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
  count         = local.kc
  name          = "alias/${local.kms_ecr}"
  target_key_id = aws_kms_key.ecr[0].key_id
}

# ── EKS CMK (Secret + ControlPlane Log) ───────────────────────
resource "aws_kms_key" "eks" {
  count                   = local.kc
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
        Principal = { AWS = local.eks_cluster_role_arn }
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
  count         = local.kc
  name          = "alias/${local.kms_eks}"
  target_key_id = aws_kms_key.eks[0].key_id
}

# ── S3 Bucket CMK ─────────────────────────────────────────────
resource "aws_kms_key" "bucket" {
  count                   = local.kc
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
  count         = local.kc
  name          = "alias/${local.kms_bucket}"
  target_key_id = aws_kms_key.bucket[0].key_id
}

# ── Lambda CMK (코드/환경변수) ────────────────────────────────
resource "aws_kms_key" "function" {
  count                   = local.kc
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
  count         = local.kc
  name          = "alias/${local.kms_function}"
  target_key_id = aws_kms_key.function[0].key_id
}
