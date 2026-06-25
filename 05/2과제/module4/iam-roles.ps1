param([string]$InstanceId, [string]$Region, [string]$DevPolicyArn, [string]$SecPolicyArn)
$ErrorActionPreference = "Continue"

$ip   = aws ec2 describe-instances --instance-ids $InstanceId --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region $Region
$acct = aws sts get-caller-identity --query Account --output text
$oidcArn = "arn:aws:iam::${acct}:oidc-provider/$ip/realms/team"
$oidcUrl = "$ip/realms/team"

function Make-Role($role, $client, $policyArn) {
  $trust = @{
    Version   = "2012-10-17"
    Statement = @(@{
        Effect    = "Allow"
        Principal = @{ Federated = $oidcArn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = @{ StringEquals = @{ "$($oidcUrl):aud" = $client } }
      })
  } | ConvertTo-Json -Depth 10

  $tf = Join-Path $env:TEMP "$role-trust.json"
  $trust | Out-File -FilePath $tf -Encoding ascii

  aws iam create-role --role-name $role --assume-role-policy-document "file://$tf" 2>$null
  if ($LASTEXITCODE -ne 0) {
    aws iam update-assume-role-policy --role-name $role --policy-document "file://$tf"
  }
  aws iam attach-role-policy --role-name $role --policy-arn $policyArn 2>$null
  Write-Host "role $role 구성 완료"
}

Make-Role "gj2026-keycloak-dev-role" "gj2026-keycloak-dev" $DevPolicyArn
Make-Role "gj2026-keycloak-sec-role" "gj2026-keycloak-sec" $SecPolicyArn
Write-Host "IAM 역할 생성 완료"
