param([string]$InstanceId, [string]$Region)
$ErrorActionPreference = "Continue"

$ip = aws ec2 describe-instances --instance-ids $InstanceId --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region $Region
Write-Host "Keycloak IP: $ip"

function Get-Thumb($h) {
  try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect($h, 443)
    $cb  = [System.Net.Security.RemoteCertificateValidationCallback] { param($s,$c,$ch,$e) $true }
    $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $cb)
    $ssl.AuthenticateAsClient($h)
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
    $tp = $cert.Thumbprint.ToLower()
    $ssl.Dispose(); $tcp.Close()
    return $tp
  } catch { return $null }
}

$thumb = $null
for ($i = 1; $i -le 60; $i++) {
  $thumb = Get-Thumb $ip
  if ($thumb) { Write-Host "Thumbprint: $thumb (시도 $i)"; break }
  Write-Host "  HTTPS 대기 중... ($i/60)"; Start-Sleep -Seconds 10
}
if (-not $thumb) { Write-Host "ERROR: HTTPS 인증서를 가져오지 못했습니다."; exit 1 }

$existing = aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[*].Arn' --output text | Select-String "$ip/realms/team"
if (-not $existing) {
  aws iam create-open-id-connect-provider --url "https://$ip/realms/team" --client-id-list gj2026-keycloak-dev gj2026-keycloak-sec --thumbprint-list $thumb
  Write-Host "OIDC Provider 생성 완료"
} else {
  Write-Host "OIDC Provider 이미 존재"
}
