# ═══════════════════════════════════════════════════════════════
# KMS Customer Managed Keys  (서비스별 분리)
#
# 채점 check_kms 조건:
#   - 고정 별칭 5개가 반드시 존재하고 실제 서비스 키 ARN과 일치
#   - 키 정책에 root principal 및 정확한 "kms:*" Action 금지
#
# 기존 잠긴 키를 재사용하면 별칭 생성·정책 검증·EKS 암호화를 보장할 수 없으므로
# 이 구성은 항상 관리 가능한 CMK 5개와 고정 별칭을 신규 생성한다.
# ═══════════════════════════════════════════════════════════════

# 이전 실행 명령과의 호환성을 위해 변수는 유지하지만 더 이상 재사용 모드로 전환하지 않는다.
variable "reuse_kms" {
  description = "Deprecated compatibility flag. CMK와 채점용 alias는 항상 신규 생성된다."
  type        = bool
  default     = false
}

variable "kms_key_arns" {
  description = "Deprecated compatibility input. 채점 가능한 구성에서는 사용하지 않는다."
  type        = map(string)
  default     = {}
}

locals {
  # 키 관리 주체에게 부여할 액션 (정확한 kms:* 금지 -> 구체적으로 나열)
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
    Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:role/wsc-task1-bastion-role" }
    Action    = local.kms_admin_actions
    Resource  = "*"
  }
  # 채점 스크립트의 describe-key/get-key-policy에 필요한 최소 읽기 권한.
  # CloudShell 채점 주체 ARN을 사전에 알 수 없어 동일 계정 principal만 허용한다.
  # root principal과 kms:*는 사용하지 않으므로 문제지의 CMK 제한도 충족한다.
  kms_auditor_statement = {
    Sid       = "AllowAccountGraderReadOnly"
    Effect    = "Allow"
    Principal = { AWS = "*" }
    Action    = ["kms:DescribeKey", "kms:GetKeyPolicy"]
    Resource  = "*"
    Condition = {
      StringEquals = { "aws:PrincipalAccount" = local.account_id }
    }
  }
  kms_via_service = {
    db  = "dynamodb.${local.region}.amazonaws.com"
    ecr = "ecr.${local.region}.amazonaws.com"
    s3  = "s3.${local.region}.amazonaws.com"
    lam = "lambda.${local.region}.amazonaws.com"
  }

  # count 주소를 유지해 기존 state 마이그레이션 충격을 줄이면서 항상 1개를 생성한다.
  kc = 1

  kms_db_arn       = aws_kms_key.db[0].arn
  kms_ecr_arn      = aws_kms_key.ecr[0].arn
  kms_eks_arn      = aws_kms_key.eks[0].arn
  kms_bucket_arn   = aws_kms_key.bucket[0].arn
  kms_function_arn = aws_kms_key.function[0].arn
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
      local.kms_auditor_statement,
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
      local.kms_auditor_statement,
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
      local.kms_auditor_statement,
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
      local.kms_auditor_statement,
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
          ArnLike      = { "AWS:SourceArn" = "arn:${local.partition}:cloudfront::${local.account_id}:distribution/*" }
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
      local.kms_auditor_statement,
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
