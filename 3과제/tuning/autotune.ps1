<#
  비파괴 사전 튜닝 권장값 계산기.

  완료된 loadtest 결과와 라이브 Deployment/HPA를 읽고 다음 네 값만 추천한다.
    - requests.cpu
    - minReplicas
    - maxReplicas
    - CPU averageUtilization

  이 스크립트는 kubectl patch, set resources, rollout, terraform apply를 실행하지 않는다.
  실제 반영은 사용자가 출력값을 검토한 뒤 Terraform에서 수동으로 수행한다.

  사용법:
    .\autotune.ps1                         # %TEMP%\tune-baseline 사용, 전체 앱
    .\autotune.ps1 -Result after1          # %TEMP%\tune-after1 사용
    .\autotune.ps1 -Result C:\path\result # 결과 폴더 직접 지정
    .\autotune.ps1 -Result baseline -App user
#>
[CmdletBinding()]
param(
  [string]$Result = 'baseline',
  [string]$App = '',
  [string]$Url = '' # 이전 호출과의 호환용. 추천 계산에는 사용하지 않는다.
)
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'config.ps1')

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  throw 'kubectl 없음 — 라이브 requests/HPA를 읽을 수 없습니다.'
}

$pythonExe = $null
$pythonPrefix = @()
if (Get-Command py -ErrorAction SilentlyContinue) {
  $pythonExe = (Get-Command py).Source
  $pythonPrefix = @('-3')
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
  $pythonExe = (Get-Command python).Source
} else {
  throw 'Python 없음 — py -3 또는 python이 필요합니다.'
}

$argsList = @((Join-Path $Here 'advise.py'), $Result, '--slos', $SLOS, '--ns', $NS)
if ($App) { $argsList += @('--app', $App) }

Write-Host '### READ-ONLY tuner: request + HPA 권장값만 계산합니다.' -ForegroundColor Cyan
Write-Host '### 클러스터/Deployment/HPA/Terraform을 변경하지 않습니다.' -ForegroundColor Cyan
$oldConsoleEncoding = [Console]::OutputEncoding
$oldOutputEncoding = $OutputEncoding
try {
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [Console]::OutputEncoding = $utf8
  $OutputEncoding = $utf8
  $env:PYTHONIOENCODING = 'utf-8'
  & $pythonExe @pythonPrefix @argsList
  if ($LASTEXITCODE -ne 0) { throw "권장값 계산 실패(exit=$LASTEXITCODE)" }
} finally {
  [Console]::OutputEncoding = $oldConsoleEncoding
  $OutputEncoding = $oldOutputEncoding
}
