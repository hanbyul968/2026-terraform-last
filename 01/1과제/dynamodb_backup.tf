resource "null_resource" "dynamo_backup" {
  triggers = {
    table = aws_dynamodb_table.wsc.arn
    role  = aws_iam_role.backup.arn
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      REGION    = local.region
      TABLE_ARN = aws_dynamodb_table.wsc.arn
      ROLE_ARN  = aws_iam_role.backup.arn
      VAULT     = "aws/efs/automatic-backup-vault"
    }
    command = <<-EOT
      set -euo pipefail

      # 이미 백업 플랜이 있으면 스킵 (멱등성)
      existing=$(aws backup list-backup-plans --region "$REGION" --query "BackupPlansList[?BackupPlanName=='wsc-dynamo-backup-plan'].BackupPlanId | [0]" --output text)
      if [ -n "$existing" ] && [ "$existing" != "None" ]; then echo "backup plan exists: $existing"; exit 0; fi

      # EFS 자동 백업이 vault 를 생성할 때까지 대기
      ok=false
      for i in $(seq 1 30); do
        if aws backup describe-backup-vault --region "$REGION" --backup-vault-name "$VAULT" >/dev/null 2>&1; then ok=true; break; fi
        sleep 10
      done
      if [ "$ok" != "true" ]; then echo "WARN: vault $VAULT 미생성/권한없음 -> AWS Backup 스킵" >&2; exit 0; fi

      if ! planId=$(aws backup create-backup-plan --region "$REGION" \
        --backup-plan '{"BackupPlanName":"wsc-dynamo-backup-plan","Rules":[{"RuleName":"wsc-dynamo-daily","TargetBackupVaultName":"'"$VAULT"'","ScheduleExpression":"cron(0 0 * * ? *)","Lifecycle":{"MoveToColdStorageAfterDays":30,"DeleteAfterDays":120}}]}' \
        --query BackupPlanId --output text 2>/tmp/bk.err); then
        echo "WARN: AWS Backup 플랜 생성 실패(권한/계정 제한 가능) -> 스킵: $(cat /tmp/bk.err)" >&2
        exit 0
      fi

      aws backup create-backup-selection --region "$REGION" \
        --backup-plan-id "$planId" \
        --backup-selection '{"SelectionName":"wsc-dynamo-selection","IamRoleArn":"'"$ROLE_ARN"'","Resources":["'"$TABLE_ARN"'"]}' >/dev/null 2>&1 || echo "WARN: backup-selection 생성 실패(무시)" >&2
      echo "backup plan: $planId"
    EOT
  }

  depends_on = [
    aws_efs_backup_policy.backup_seed,
    aws_iam_role_policy_attachment.backup_backup,
    aws_dynamodb_table.wsc,
  ]
}

