resource "null_resource" "dynamo_backup" {
  triggers = {
    table = aws_dynamodb_table.wsc.arn
    role  = aws_iam_role.backup.arn
  }

  provisioner "local-exec" {
    interpreter = ["powershell", "-NoProfile", "-Command"]
    environment = {
      REGION    = local.region
      TABLE_ARN = aws_dynamodb_table.wsc.arn
      ROLE_ARN  = aws_iam_role.backup.arn
      VAULT     = "aws/efs/automatic-backup-vault"
    }
    command = <<-EOT
      $ErrorActionPreference = 'Stop'

      # 이미 백업 플랜이 있으면 스킵 (멱등성)
      $existing = aws backup list-backup-plans --region $env:REGION --query "BackupPlansList[?BackupPlanName=='wsc-dynamo-backup-plan'].BackupPlanId | [0]" --output text
      if ($existing -and $existing -ne 'None') { Write-Host "backup plan exists: $existing"; exit 0 }

      # EFS 자동 백업이 vault 를 생성할 때까지 대기
      $ok = $false
      for ($i=0; $i -lt 30; $i++) {
        aws backup describe-backup-vault --region $env:REGION --backup-vault-name $env:VAULT 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ok = $true; break }
        Start-Sleep -Seconds 10
      }
      if (-not $ok) { throw "vault $($env:VAULT) not available" }

      $tmp = [System.IO.Path]::GetTempPath()
      $planFile = Join-Path $tmp 'wsc-backup-plan.json'
      $selFile  = Join-Path $tmp 'wsc-backup-sel.json'

      $plan = @{
        BackupPlanName = 'wsc-dynamo-backup-plan'
        Rules = @(@{
          RuleName = 'wsc-dynamo-daily'
          TargetBackupVaultName = $env:VAULT
          ScheduleExpression = 'cron(0 0 * * ? *)'
          Lifecycle = @{ MoveToColdStorageAfterDays = 30; DeleteAfterDays = 120 }
        })
      }
      @{ BackupPlan = $plan } | ConvertTo-Json -Depth 10 | Out-File -Encoding ascii $planFile

      $planId = aws backup create-backup-plan --region $env:REGION --cli-input-json "file://$planFile" --query BackupPlanId --output text
      if ($LASTEXITCODE -ne 0) { throw "create-backup-plan failed" }

      $sel = @{
        BackupPlanId = $planId
        BackupSelection = @{
          SelectionName = 'wsc-dynamo-selection'
          IamRoleArn = $env:ROLE_ARN
          Resources = @($env:TABLE_ARN)
        }
      }
      $sel | ConvertTo-Json -Depth 10 | Out-File -Encoding ascii $selFile
      aws backup create-backup-selection --region $env:REGION --cli-input-json "file://$selFile" | Out-Null
      if ($LASTEXITCODE -ne 0) { throw "create-backup-selection failed" }
      Write-Host "backup plan created: $planId"
    EOT
  }

  depends_on = [
    aws_efs_backup_policy.backup_seed,
    aws_iam_role_policy_attachment.backup_backup,
    aws_dynamodb_table.wsc,
  ]
}

