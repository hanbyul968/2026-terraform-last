<#
  Windows PowerShell 부트스트랩 (cloudshell-setup.sh 의 대응판).
  hey.exe + kubectl.exe 를 %USERPROFILE%\bin 에 설치하고 PATH 에 등록, kubeconfig 를 쓴다.
  전제: aws CLI, python 은 이미 설치돼 있어야 한다 (aws --version, python --version).

  사용법:
    .\setup.ps1 -Cluster wsi2026-cluster -Region ap-northeast-2

  자격증명은 `aws configure` 로 설정돼 있어야 한다(CloudShell 처럼 ambient 아님).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Cluster,
  [string]$Region = 'ap-northeast-2'
)
$ErrorActionPreference = 'Stop'
$bin = Join-Path $env:USERPROFILE 'bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null

# --- PATH 등록 (현재 세션 + 사용자 환경 영구) ---
if ($env:Path -notlike "*$bin*") { $env:Path = "$bin;$env:Path" }
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$bin*") {
  [Environment]::SetEnvironmentVariable('Path', "$bin;$userPath", 'User')
  Write-Host "PATH 에 $bin 등록(새 창부터 자동 적용)"
}

# --- kubectl ---
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  Write-Host 'installing kubectl...'
  $kv = (Invoke-RestMethod 'https://dl.k8s.io/release/stable.txt').Trim()
  Invoke-WebRequest "https://dl.k8s.io/release/$kv/bin/windows/amd64/kubectl.exe" -OutFile (Join-Path $bin 'kubectl.exe')
}

# --- hey ---
if (-not (Get-Command hey -ErrorAction SilentlyContinue)) {
  Write-Host 'installing hey...'
  Invoke-WebRequest 'https://hey-release.s3.us-east-2.amazonaws.com/hey_windows_amd64' -OutFile (Join-Path $bin 'hey.exe')
}

# --- kubeconfig ---
Write-Host "writing kubeconfig for $Cluster ($Region)..."
aws eks update-kubeconfig --name $Cluster --region $Region

Write-Host ''
Write-Host '=== ready ==='
try { (kubectl version --client 2>$null | Select-Object -First 1) } catch {}
if (Get-Command hey -ErrorAction SilentlyContinue) { Write-Host 'hey: ok' }
python --version
Write-Host ''
Write-Host 'sanity:  kubectl -n app get pods'
Write-Host '먼저:    config.ps1 의 $ENDPOINT 에 엔드포인트 한 번 붙여넣기'
Write-Host 'run:     .\loadtest.ps1 180s baseline'
Write-Host 'tune:    .\autotune.ps1 -App stress'
