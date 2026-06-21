############################
# DynamoDB table (AWS managed KMS, PITR, deletion protection, on-demand)
############################
resource "aws_dynamodb_table" "wsc" {
  name                        = local.table_name
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "booking_id"
  deletion_protection_enabled = true

  attribute {
    name = "booking_id"
    type = "S"
  }

  # enabled=true (kms_key_arn ????? => AWS ????? ??aws/dynamodb (SSEType KMS)
  server_side_encryption {
    enabled = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Name = local.table_name }
}

############################
# EFS - automatic backup ?????? 'aws/efs/automatic-backup-vault' ??? ???
############################
resource "aws_efs_file_system" "backup_seed" {
  creation_token = "wsc-backup-seed"
  encrypted      = true
  tags           = { Name = "wsc-backup-seed" }
}

resource "aws_efs_backup_policy" "backup_seed" {
  file_system_id = aws_efs_file_system.backup_seed.id
  backup_policy {
    status = "ENABLED"
  }
}

############################
# AWSBackupDefaultServiceRole
############################
resource "aws_iam_role" "backup" {
  name = "AWSBackupDefaultServiceRole"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup_backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

############################
# Backup plan + selection -> aws/efs/automatic-backup-vault
#   provider ?? ???????? vault ?????????????AWS CLI ?????.
#   plan: wsc-dynamo-backup-plan, cron(0 0 * * ? *), cold 30 / delete 120
############################
# TEMPORARILY DISABLED - backup plan creation
# 
